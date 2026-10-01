import AppKit
import Foundation
import Observation
import TVThingKit

/// App-wide state for the UI: mirrors the engine's snapshots, owns the companion audio
/// player, and persists user preferences.
@MainActor
@Observable
final class AppModel {
    let engine: TVThingEngine
    let audio: CompanionAudio
    let setup: SetupMonitor

    private(set) var snapshot = EngineSnapshot.initial
    /// A user-facing error from the last action, shown until dismissed.
    var alert: String?
    /// The outcome of an import that skipped duplicates, shown until dismissed.
    var importNotice: String?

    /// Opens the Settings window, optionally at a section. Provided by the app delegate.
    @ObservationIgnored var openSettings: (SettingsTab?) -> Void = { _ in }

    var ffmpegPath: String {
        didSet { Preferences.ffmpegPath = ffmpegPath }
    }

    var display: DisplayOptions {
        didSet {
            Preferences.display = display
            let options = display
            Task { await engine.setDisplay(options) }
        }
    }

    var library: ChannelLibrary { snapshot.library }
    var currentChannel: Channel? { library.currentChannel }
    var registry: ProviderRegistry { engine.registry }

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        engine = TVThingEngine(configuration: EngineConfiguration(
            appVersion: version,
            customFFmpegPath: { Preferences.ffmpegPath }
        ))
        audio = CompanionAudio(engine: engine)
        setup = SetupMonitor()
        ffmpegPath = Preferences.ffmpegPath
        display = Preferences.display

        audio.isEnabled = Preferences.audioEnabled
        audio.offsetMs = Preferences.offsetMs

        Task { await start() }
    }

    private func start() async {
        await engine.setDisplay(display)
        await engine.setVolume(Preferences.volume)
        await engine.start()
        audio.start()
        setup.start()
        for await snapshot in engine.snapshots {
            self.snapshot = snapshot
            audio.setStream(snapshot.streamURL)
            audio.isMuted = snapshot.muted
            audio.setPictureVisible(snapshot.pictureVisible)
            if audio.volume != snapshot.volume {
                audio.volume = snapshot.volume
                Preferences.volume = snapshot.volume
            }
            setup.update(from: snapshot)
        }
    }

    func shutdown() async {
        audio.stop()
        await engine.shutdown()
    }

    // MARK: - Playback

    func tune(_ target: TuneTarget) {
        Task { await engine.tune(target) }
    }

    func restartStream() {
        audio.resync()
        Task { await engine.restartStream() }
    }

    func toggleMute() {
        Task { await engine.setMuted(nil) }
    }

    func setAudioEnabled(_ enabled: Bool) {
        audio.isEnabled = enabled
        Preferences.audioEnabled = enabled
    }

    /// The engine owns volume so the Mac slider and the Car Thing's knob stay in step.
    func setVolume(_ volume: Float) {
        audio.volume = volume
        Task { await engine.setVolume(volume) }
    }

    func adjustOffset(by delta: Int) {
        setOffset(audio.offsetMs + delta)
    }

    func setOffset(_ value: Int) {
        audio.offsetMs = value
        Preferences.offsetMs = audio.offsetMs
    }

    // MARK: - Library

    func add(_ channel: Channel, favoriteSlot: Int?) {
        Task {
            await engine.addChannel(channel)
            if let favoriteSlot { await engine.setFavorite(channel.id, slot: favoriteSlot) }
        }
    }

    func update(_ channel: Channel, favoriteSlot: Int?) {
        Task {
            await engine.updateChannel(channel)
            await applyFavorite(favoriteSlot, to: channel.id)
        }
    }

    func remove(_ ids: Set<Channel.ID>) {
        Task { await engine.removeChannels(ids) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        Task { await engine.moveChannels(fromOffsets: source, toOffset: destination) }
    }

    func setFavorite(_ id: Channel.ID?, slot: Int) {
        Task { await engine.setFavorite(id, slot: slot) }
    }

    private func applyFavorite(_ slot: Int?, to id: Channel.ID) async {
        let existing = library.favoriteSlot(of: id)
        guard slot != existing else { return }
        if let existing { await engine.setFavorite(nil, slot: existing) }
        if let slot { await engine.setFavorite(id, slot: slot) }
    }

    func importChannels(from url: URL) {
        Task {
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let result = try await engine.importChannels(from: Data(contentsOf: url))
                await engine.log.record("Imported \(result.added) channels from \(url.lastPathComponent) (\(result.skipped) already present)", source: .mac)
                if result.added == 0 {
                    importNotice = "Every channel in this file is already in your lineup."
                } else if result.skipped > 0 {
                    let added = result.added == 1 ? "1 new channel" : "\(result.added) new channels"
                    let skipped = result.skipped == 1 ? "1 was" : "\(result.skipped) were"
                    importNotice = "Added \(added). \(skipped) already in your lineup."
                }
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func exportChannels(to url: URL, ids: Set<Channel.ID>?) {
        Task {
            do {
                let name = url.deletingPathExtension().lastPathComponent
                try await engine.exportChannels(ids, name: name).write(to: url, options: .atomic)
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    /// Adds the starter channels bundled with the app: free streams broadcasters publish themselves.
    func importStarterChannels() {
        guard let url = Bundle.main.url(forResource: "Starter Channels", withExtension: ChannelPack.fileExtension) else { return }
        importChannels(from: url)
    }
}

/// User preferences stored in `UserDefaults`.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var audioEnabled: Bool {
        get { defaults.object(forKey: "AudioEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "AudioEnabled") }
    }

    static var volume: Float {
        get { defaults.object(forKey: "Volume") as? Float ?? 0.8 }
        set { defaults.set(newValue, forKey: "Volume") }
    }

    static var offsetMs: Int {
        get { defaults.integer(forKey: "AudioOffsetMs") }
        set { defaults.set(newValue, forKey: "AudioOffsetMs") }
    }

    static var ffmpegPath: String {
        get { defaults.string(forKey: "FFmpegPath") ?? "" }
        set { defaults.set(newValue, forKey: "FFmpegPath") }
    }

    static var display: DisplayOptions {
        get { defaults.data(forKey: "Display").flatMap { try? JSONDecoder().decode(DisplayOptions.self, from: $0) } ?? DisplayOptions() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "Display") }
    }

    static var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: "HasCompletedSetup") }
        set { defaults.set(newValue, forKey: "HasCompletedSetup") }
    }
}
