import Foundation

/// How the current channel reaches the Car Thing.
public enum Delivery: Equatable, Sendable {
    /// Relayed untouched.
    case direct
    /// Re-encoded by FFmpeg.
    case converted(reason: String)
    /// Needed conversion, but FFmpeg isn't installed; relayed as-is on a best-effort basis.
    case unconverted(reason: String)
}

public enum StreamPhase: Equatable, Sendable {
    case preparing
    case playing(Delivery)
    case failed(String)
}

/// One tune of one channel, served under `/stream/<id>/`.
///
/// A new session (with a new ID) is created on every channel change, so requests left
/// over from the previous channel fail cleanly instead of mixing streams.
///
/// Routes below the session path:
/// - `index.m3u8`: what the Car Thing and the Mac's audio player load
/// - `source.m3u8`, `s/<token>`: the relayed upstream stream (also FFmpeg's input)
/// - `o/<token>`: FFmpeg's output
actor StreamSession {
    struct Environment: Sendable {
        var registry: ProviderRegistry
        var http: HTTPClient
        var log: DiagnosticsLog
        /// e.g. `http://127.0.0.1:17839`
        var origin: URL
        var ffmpeg: @Sendable () -> URL?
    }

    nonisolated let id: String
    nonisolated let channel: Channel
    nonisolated var playlistPath: String { "\(basePath)/index.m3u8" }
    private nonisolated var basePath: String { "/stream/\(id)" }

    private let environment: Environment
    private let onPhaseChange: @Sendable (StreamPhase) async -> Void
    private var preparation: Task<Delivery, Error>?
    private var failedAt: Date?
    private var sourceRelay: HLSRelay?
    private var transcoder: FFmpegTranscoder?
    /// What FFmpeg should convert; set while preparing.
    private var conversion = (onDemand: false, program: Int?.none)
    private var output: (playlist: URL, relay: HLSRelay)?
    private var lastAccess = Date.now
    private var stopped = false

    init(id: String, channel: Channel, environment: Environment, onPhaseChange: @escaping @Sendable (StreamPhase) async -> Void) {
        self.id = id
        self.channel = channel
        self.environment = environment
        self.onPhaseChange = onPhaseChange
    }

    func stop() async {
        stopped = true
        preparation?.cancel()
        await transcoder?.stop()
    }

    /// Stops FFmpeg when nobody has requested anything for a while. It restarts on demand.
    func suspendIfIdle(after interval: TimeInterval) async {
        guard let transcoder, await transcoder.isRunning, Date.now.timeIntervalSince(lastAccess) > interval else { return }
        await transcoder.stop()
        output = nil
        await environment.log.record("Paused conversion while nothing is watching", source: .mac)
    }

    func handle(_ route: ArraySlice<String>, range: String?) async throws -> HTTPResponse {
        guard !stopped else { throw HTTPError(status: 404, message: "This channel is no longer playing") }
        lastAccess = .now
        switch Array(route) {
        case ["index.m3u8"]:
            switch try await preparationTask().value {
            case .converted: return try await convertedEntry(range: range)
            case .direct, .unconverted: return try await requireSourceRelay().entry(range: range)
            }
        case ["source.m3u8"]:
            // FFmpeg reads this while preparation is still waiting on FFmpeg, so only the
            // relay (created early in preparation) is required here.
            if sourceRelay == nil { _ = try await preparationTask().value }
            return try await requireSourceRelay().entry(range: range)
        case let parts where parts.count == 2 && parts[0] == "s":
            return try await requireSourceRelay().media(token: parts[1], range: range)
        case let parts where parts.count == 2 && parts[0] == "o":
            guard let output else { throw HTTPError(status: 404, message: "Conversion restarted") }
            return try await output.relay.media(token: parts[1], range: range)
        default:
            throw HTTPError(status: 404, message: "Not found")
        }
    }

    // MARK: - Preparation

    /// Returns the in-progress or finished preparation, retrying a failed one after a pause.
    private func preparationTask() -> Task<Delivery, Error> {
        if let preparation, failedAt.map({ Date.now.timeIntervalSince($0) < 3 }) ?? true {
            return preparation
        }
        failedAt = nil
        let task = Task { try await self.prepare() }
        preparation = task
        return task
    }

    private func prepare() async throws -> Delivery {
        await onPhaseChange(.preparing)
        do {
            let resolved = try await environment.registry.resolve(channel.source)
            sourceRelay = makeSourceRelay(resolved)
            let source = try await sourcePlaylists()
            conversion = (source.media.hasEndList, source.multivariant.flatMap(CompatibilityProbe.conversionVariant))
            let delivery = try await chooseDelivery(source)
            if case .converted = delivery { _ = try await convertedEntry(range: nil) }
            await environment.log.record("Tuned “\(channel.name)” (\(Self.describe(delivery)))", source: .mac)
            await onPhaseChange(.playing(delivery))
            return delivery
        } catch {
            failedAt = .now
            let message = error.localizedDescription
            await environment.log.record("“\(channel.name)” failed: \(message)", source: .mac)
            if !stopped { await onPhaseChange(.failed(message)) }
            throw error
        }
    }

    private func makeSourceRelay(_ resolved: ResolvedStream) -> HLSRelay {
        let registry = environment.registry
        let source = channel.source
        let log = environment.log
        return HLSRelay(
            mediaPrefix: "\(basePath)/s/",
            upstream: .init(entryURL: resolved.playlistURL, prepare: resolved.prepare),
            http: environment.http,
            onUnauthorized: {
                await log.record("Upstream rejected a request; refreshing the session", source: .mac)
                guard let refreshed = try? await registry.resolve(source, refresh: true) else { return nil }
                return .init(entryURL: refreshed.playlistURL, prepare: refreshed.prepare)
            }
        )
    }

    private func chooseDelivery(_ source: SourcePlaylists) async throws -> Delivery {
        let ffmpegAvailable = environment.ffmpeg() != nil
        switch channel.playback {
        case .direct:
            return .direct
        case .convert:
            guard ffmpegAvailable else {
                throw HTTPError(status: 503, message: "This channel is set to always convert, but FFmpeg isn't installed.")
            }
            return .converted(reason: "Set to always convert")
        case .automatic:
            switch await probe(source) {
            case .direct: return .direct
            case .needsConversion(let reason):
                return ffmpegAvailable ? .converted(reason: reason) : .unconverted(reason: reason)
            }
        }
    }

    /// The entry playlist and the media playlist the Car Thing would play from it.
    private struct SourcePlaylists {
        var multivariant: HLSPlaylist?
        var media: HLSPlaylist
    }

    /// Reads the stream through the relay, which also warms its cache.
    private func sourcePlaylists() async throws -> SourcePlaylists {
        let relay = try requireSourceRelay()
        let entry = HLSPlaylist(try Self.text(of: try await relay.entry(range: nil)))
        guard entry.isMultivariant else { return SourcePlaylists(multivariant: nil, media: entry) }
        guard let variant = CompatibilityProbe.preferredVariant(in: entry), let token = Self.token(of: variant.uri) else {
            return SourcePlaylists(multivariant: entry, media: entry)
        }
        let media = HLSPlaylist(try Self.text(of: try await relay.media(token: token, range: nil)))
        return SourcePlaylists(multivariant: entry, media: media)
    }

    /// Judges whether the Car Thing can play the stream as-is.
    private func probe(_ source: SourcePlaylists) async -> StreamCompatibility {
        let segmentBytes: Int? = if let relay = sourceRelay { await sampleSegmentSize(in: source.media, relay: relay) } else { nil }
        return CompatibilityProbe.evaluate(multivariant: source.multivariant, media: source.media, segmentBytes: segmentBytes)
    }

    /// Fetches the newest segment, where playback starts, so the relay also has it cached.
    private func sampleSegmentSize(in media: HLSPlaylist, relay: HLSRelay) async -> Int? {
        guard let uri = media.segmentURIs.last, let token = Self.token(of: uri) else { return nil }
        return try? await relay.media(token: token, range: nil).body.count
    }

    /// Relay URIs end in their token: `/stream/<session>/s/<token>`.
    private static func token(of uri: String) -> String? {
        uri.split(separator: "/").last.map(String.init)
    }

    private func convertedEntry(range: String?) async throws -> HTTPResponse {
        let transcoder = try requireTranscoder()
        let playlist = try await transcoder.playlist()
        if output?.playlist != playlist {
            let relay = HLSRelay(
                mediaPrefix: "\(basePath)/o/",
                upstream: .init(entryURL: playlist, prepare: { _ in }),
                http: environment.http,
                onUnauthorized: { nil }
            )
            output = (playlist, relay)
        }
        return try await output!.relay.entry(range: range)
    }

    private func requireTranscoder() throws -> FFmpegTranscoder {
        if let transcoder { return transcoder }
        guard let executable = environment.ffmpeg() else {
            throw HTTPError(status: 503, message: "FFmpeg isn't installed.")
        }
        let input = URL(string: environment.origin.absoluteString + "\(basePath)/source.m3u8")!
        let transcoder = FFmpegTranscoder(
            executable: executable,
            source: .init(url: input, onDemand: conversion.onDemand, program: conversion.program),
            log: environment.log
        )
        self.transcoder = transcoder
        return transcoder
    }

    private func requireSourceRelay() throws -> HLSRelay {
        guard let sourceRelay else { throw HTTPError(status: 503, message: "Stream isn't ready yet") }
        return sourceRelay
    }

    private static func text(of response: HTTPResponse) throws -> String {
        guard let text = String(data: response.body, encoding: .utf8) else { throw ProviderError.notAPlaylist }
        return text
    }

    private static func describe(_ delivery: Delivery) -> String {
        switch delivery {
        case .direct: "direct"
        case .converted(let reason): "converting: \(reason)"
        case .unconverted(let reason): "direct without FFmpeg: \(reason)"
        }
    }
}
