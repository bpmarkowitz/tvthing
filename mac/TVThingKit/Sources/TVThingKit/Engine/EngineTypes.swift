import Foundation

public struct EngineConfiguration: Sendable {
    public var port: UInt16
    public var store: LibraryStore
    public var registry: ProviderRegistry
    public var http: HTTPClient
    public var appVersion: String
    /// A user-chosen FFmpeg path, read on every tune so Settings changes apply immediately.
    public var customFFmpegPath: @Sendable () -> String?

    public init(
        port: UInt16 = 17_839,
        store: LibraryStore = LibraryStore(fileURL: LibraryStore.defaultFileURL),
        registry: ProviderRegistry = .standard(),
        http: HTTPClient = .shared,
        appVersion: String = "1.0",
        customFFmpegPath: @escaping @Sendable () -> String? = { nil }
    ) {
        self.port = port
        self.store = store
        self.registry = registry
        self.http = http
        self.appVersion = appVersion
        self.customFFmpegPath = customFFmpegPath
    }
}

public enum DeviceConnection: Equatable, Sendable {
    case waiting
    case connected(playing: Bool)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Everything the Mac UI renders, published whenever it changes.
public struct EngineSnapshot: Equatable, Sendable {
    public var library: ChannelLibrary
    public var server: LocalHTTPServer.State
    public var device: DeviceConnection
    /// `nil` until something requests the current channel's stream.
    public var phase: StreamPhase?
    public var sessionID: String?
    /// The current stream on the local server, for the Mac's audio player.
    public var streamURL: URL?
    /// Mac audio muted, from the menu or a Car Thing button. The picture keeps playing.
    public var muted = false
    /// Mac audio volume, 0–1, from the menu or the Car Thing's knob.
    public var volume: Float = 0.8
    /// False while the Car Thing hides the picture; published the moment it changes so
    /// the Mac's audio can go silent with it.
    public var pictureVisible = true

    public static let initial = EngineSnapshot(library: ChannelLibrary(), server: .starting, device: .waiting)
}

/// The Car Thing's latest playback report.
public struct DeviceTimeline: Sendable, Equatable {
    public var sessionID: String
    /// Program-date-time of the frame on screen, in Unix milliseconds.
    public var positionMs: Double?
    public var playing: Bool
    /// Changes whenever the Car Thing restarts playback, e.g. reloading after a stall.
    public var generation: Int
    /// False while the Car Thing hides the picture; audio stays silent to match.
    public var pictureVisible: Bool
    public var receivedAt: Date
}

/// How the Car Thing presents the picture. Owned by the app's preferences and pushed
/// to the engine, which forwards it to the Car Thing in `/api/v1/state`.
public struct DisplayOptions: Codable, Equatable, Sendable {
    /// Horizontal CRT scanlines over the picture.
    public var scanlines: Bool

    public init(scanlines: Bool = false) {
        self.scanlines = scanlines
    }
}

public struct ImportResult: Sendable, Equatable {
    public var added: Int
    /// Channels left out because the lineup already had them.
    public var skipped: Int
}

public enum TuneTarget: Sendable, Equatable {
    case channel(Channel.ID)
    case favorite(Int)
    case step(Int)
}
