import Foundation

/// The heart of TV Thing: owns the channel library, the current stream session, and the
/// local server the Car Thing talks to. The UI observes `snapshots` and calls in to act.
public actor TVThingEngine {
    public nonisolated let snapshots: AsyncStream<EngineSnapshot>
    public nonisolated let log = DiagnosticsLog()
    public nonisolated let registry: ProviderRegistry
    /// `true` when no library had been saved before this launch.
    public nonisolated let isFirstLaunch: Bool

    private static let deviceTimeout: TimeInterval = 3
    private static let idleConversionTimeout: TimeInterval = 45

    private let configuration: EngineConfiguration
    private let continuation: AsyncStream<EngineSnapshot>.Continuation
    private var server: LocalHTTPServer?
    private var housekeeping: Task<Void, Never>?

    private var library: ChannelLibrary
    private var session: StreamSession?
    private var snapshot = EngineSnapshot.initial
    private var revision = 1
    private var timeline: DeviceTimeline?
    private var display = DisplayOptions()

    public init(configuration: EngineConfiguration = EngineConfiguration()) {
        self.configuration = configuration
        self.registry = configuration.registry
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stored = try? configuration.store.load()
        isFirstLaunch = stored == nil
        library = stored ?? ChannelLibrary()
    }

    // MARK: - Lifecycle

    public func start() {
        guard server == nil else { return }
        FFmpegTranscoder.removeStaleOutput()
        let server = LocalHTTPServer(port: configuration.port) { [weak self] request in
            guard let self else { return .notFound }
            return await self.respond(to: request)
        }
        self.server = server
        do {
            try server.start { [weak self] state in
                Task { await self?.serverStateChanged(state) }
            }
        } catch {
            serverStateChanged(.failed(error.localizedDescription))
        }
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.performHousekeeping()
            }
        }
        publish()
    }

    public func shutdown() async {
        housekeeping?.cancel()
        server?.stop()
        await session?.stop()
        continuation.finish()
    }

    // MARK: - Library

    public func addChannel(_ channel: Channel) {
        library.add(channel)
        libraryChanged()
    }

    public func updateChannel(_ channel: Channel) {
        let previous = library.channel(withID: channel.id)
        library.update(channel)
        // Changing what the current channel plays requires a fresh stream.
        if channel.id == library.currentChannelID,
           previous?.source != channel.source || previous?.playback != channel.playback {
            replaceSession()
        }
        libraryChanged()
    }

    public func removeChannels(_ ids: Set<Channel.ID>) {
        let removingCurrent = library.currentChannelID.map(ids.contains) ?? false
        library.remove(ids: ids)
        if removingCurrent { replaceSession() }
        libraryChanged()
    }

    public func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.move(fromOffsets: source, toOffset: destination)
        libraryChanged()
    }

    public func setFavorite(_ id: Channel.ID?, slot: Int) {
        library.setFavorite(id, at: slot)
        libraryChanged()
    }

    /// Imports a TV Thing channel pack or M3U playlist, skipping channels already in the lineup.
    @discardableResult
    public func importChannels(from data: Data) throws -> ImportResult {
        importChannels(try ChannelPack.decode(data).makeChannels())
    }

    /// Adds channels, skipping any already in the lineup.
    @discardableResult
    public func importChannels(_ channels: [Channel]) -> ImportResult {
        let wasEmpty = library.channels.isEmpty
        let added = library.merge(channels)
        if wasEmpty {
            // Give a brand-new lineup favorites straight away.
            for (slot, channel) in added.prefix(ChannelLibrary.favoriteSlotCount).enumerated() {
                library.setFavorite(channel.id, at: slot)
            }
        }
        if !added.isEmpty { libraryChanged() }
        return ImportResult(added: added.count, skipped: channels.count - added.count)
    }

    public func exportChannels(_ ids: Set<Channel.ID>? = nil, name: String? = nil) throws -> Data {
        let channels = library.channels.filter { ids?.contains($0.id) ?? true }
        return try ChannelPack(name: name, exporting: channels).encoded()
    }

    // MARK: - Display

    public func setDisplay(_ options: DisplayOptions) {
        guard options != display else { return }
        display = options
        bumpRevision()
    }

    // MARK: - Audio

    /// Twenty steps from silent to full, like an old TV's volume bar.
    public static let volumeStep: Float = 0.05

    public func setVolume(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        guard clamped != snapshot.volume else { return }
        snapshot.volume = clamped
        bumpRevision()
    }

    /// Moves the volume by knob detents. Turning it up also unmutes, like a TV.
    public func adjustVolume(bySteps steps: Int) {
        let current = (snapshot.volume / Self.volumeStep).rounded()
        setVolume((current + Float(steps)) * Self.volumeStep)
        if steps > 0, snapshot.muted { setMuted(false) }
    }

    /// Mutes the Mac's audio while the Car Thing keeps showing the picture. `nil` toggles.
    public func setMuted(_ muted: Bool?) {
        snapshot.muted = muted ?? !snapshot.muted
        bumpRevision()
    }

    // MARK: - Playback

    public func tune(_ target: TuneTarget) {
        let channel: Channel? = switch target {
        case .channel(let id): library.channel(withID: id)
        case .favorite(let slot): library.favorite(at: slot)
        case .step(let step): library.channel(steppingBy: step)
        }
        guard let channel, channel.id != library.currentChannelID else { return }
        library.setCurrentChannel(channel.id)
        replaceSession()
        libraryChanged()
    }

    /// Starts the current channel over, e.g. after fixing a network problem.
    public func restartStream() {
        replaceSession()
        bumpRevision()
    }

    public func deviceTimeline() -> DeviceTimeline? {
        guard let timeline, timeline.sessionID == session?.id else { return nil }
        return timeline
    }

    // MARK: - State

    private func libraryChanged() {
        do {
            try configuration.store.save(library)
        } catch {
            Task { await log.record("Couldn't save channels: \(error.localizedDescription)", source: .mac) }
        }
        bumpRevision()
    }

    private func bumpRevision() {
        revision += 1
        publish()
    }

    private func replaceSession() {
        let previous = session
        session = nil
        snapshot.phase = nil
        Task { await previous?.stop() }
    }

    /// The session for the current channel. Creating one is cheap; it only starts
    /// resolving and relaying when a player first requests its playlist.
    private func currentSession() -> StreamSession? {
        if let session { return session }
        guard let channel = library.currentChannel else { return nil }
        let environment = StreamSession.Environment(
            registry: configuration.registry,
            http: configuration.http,
            log: log,
            origin: origin,
            ffmpeg: { [configuration] in FFmpegLocator.locate(customPath: configuration.customFFmpegPath()) }
        )
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let created = StreamSession(id: id, channel: channel, environment: environment) { [weak self] phase in
            await self?.sessionPhaseChanged(phase, sessionID: id)
        }
        session = created
        return created
    }

    private func sessionPhaseChanged(_ phase: StreamPhase, sessionID: String) {
        // Ignore late reports from a session that has since been replaced.
        guard session?.id == sessionID else { return }
        snapshot.phase = phase
        bumpRevision()
    }

    private func serverStateChanged(_ state: LocalHTTPServer.State) {
        snapshot.server = state
        if case .failed(let message) = state {
            Task { await log.record("Local server: \(message)", source: .mac) }
        }
        publish()
    }

    private func performHousekeeping() async {
        let device: DeviceConnection
        if let timeline, Date.now.timeIntervalSince(timeline.receivedAt) < Self.deviceTimeout {
            device = .connected(playing: timeline.playing)
        } else {
            device = .waiting
        }
        if device != snapshot.device {
            snapshot.device = device
            publish()
        }
        await session?.suspendIfIdle(after: Self.idleConversionTimeout)
    }

    private func publish() {
        snapshot.library = library
        let current = currentSession()
        snapshot.sessionID = current?.id
        snapshot.streamURL = current.flatMap { URL(string: origin.absoluteString + $0.playlistPath) }
        continuation.yield(snapshot)
    }

    private var origin: URL {
        URL(string: "http://127.0.0.1:\(configuration.port)")!
    }

    // MARK: - HTTP

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        do {
            return try await route(request)
        } catch let error as HTTPError {
            return .error(error.message, status: error.status)
        } catch {
            return .error(error.localizedDescription, status: 502)
        }
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let parts = request.pathComponents
        switch (request.method, parts) {
        case ("GET", ["api", "v1", "health"]):
            return .json(DeviceAPI.Health(version: configuration.appVersion))

        case ("GET", ["api", "v1", "state"]):
            return .json(deviceState())

        case ("POST", ["api", "v1", "tune"]):
            let body = try request.decodeBody(DeviceAPI.TuneRequest.self)
            if let id = body.channel { tune(.channel(id)) }
            else if let slot = body.favorite { tune(.favorite(slot)) }
            else if let step = body.step { tune(.step(step)) }
            return .json(deviceState())

        case ("POST", ["api", "v1", "favorites"]):
            let body = try request.decodeBody(DeviceAPI.FavoriteRequest.self)
            setFavorite(body.channel ?? library.currentChannelID, slot: body.slot)
            return .json(deviceState())

        case ("POST", ["api", "v1", "sync"]):
            let body = try request.decodeBody(DeviceAPI.SyncReport.self)
            timeline = DeviceTimeline(sessionID: body.session, positionMs: body.position, playing: body.playing, generation: body.generation ?? 0, pictureVisible: body.visible ?? true, receivedAt: .now)
            let visible = body.visible ?? true
            if visible != snapshot.pictureVisible {
                snapshot.pictureVisible = visible
                publish()
            }
            return .json(DeviceAPI.OK())

        case ("POST", ["api", "v1", "mute"]):
            setMuted(try request.decodeBody(DeviceAPI.MuteRequest.self).muted)
            return .json(deviceState())

        case ("POST", ["api", "v1", "volume"]):
            let body = try request.decodeBody(DeviceAPI.VolumeRequest.self)
            if let level = body.level { setVolume(level) }
            if let steps = body.steps { adjustVolume(bySteps: steps) }
            return .json(deviceState())

        case ("POST", ["api", "v1", "log"]):
            let body = try request.decodeBody(DeviceAPI.LogRequest.self)
            await log.record(String(body.message.prefix(500)), source: .device)
            return .json(DeviceAPI.OK())

        case ("GET", let path) where path.first == "stream":
            return try await routeStream(Array(path.dropFirst()), request: request)


        default:
            throw HTTPError(status: 404, message: "Not found")
        }
    }

    /// `/stream/<session>/…`
    private func routeStream(_ path: [String], request: HTTPRequest) async throws -> HTTPResponse {
        guard let session = currentSession(), path.count >= 2, path[0] == session.id else {
            throw HTTPError(status: 404, message: "This stream has ended")
        }
        return try await session.handle(path.dropFirst(), range: request.headers["range"])
    }

    private func deviceState() -> DeviceAPI.State {
        let active = currentSession()
        let channels = library.channels.enumerated().map { index, channel in
            DeviceAPI.ChannelInfo(id: channel.id, number: index + 1, name: channel.name, favorite: library.favoriteSlot(of: channel.id))
        }
        let (phase, message): (String, String?) = switch snapshot.phase {
        case nil, .preparing: ("preparing", nil)
        case .playing: ("playing", nil)
        case .failed(let reason): ("failed", reason)
        }
        return DeviceAPI.State(
            revision: revision,
            session: active.map { .init(id: $0.id, playlist: $0.playlistPath) },
            channel: channels.first { $0.id == library.currentChannelID },
            channels: channels,
            phase: library.channels.isEmpty ? "empty" : phase,
            message: message,
            display: display,
            muted: snapshot.muted,
            volume: snapshot.volume
        )
    }
}
