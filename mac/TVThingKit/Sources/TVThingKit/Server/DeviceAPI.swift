import Foundation

/// The JSON contract between the Mac app and the Car Thing webapp.
/// Mirrored in `carthing/src/api.ts`; see `docs/device-api.md`.
enum DeviceAPI {
    static let version = 1

    struct State: Encodable {
        var api = DeviceAPI.version
        /// Changes whenever anything the Car Thing displays changes.
        var revision: Int
        /// Changes only when the stream itself changes; the Car Thing restarts playback then.
        var session: Session?
        var channel: ChannelInfo?
        var channels: [ChannelInfo]
        var phase: String
        var message: String?
        var display: DisplayOptions
        var muted: Bool
        var volume: Float
    }

    struct VolumeRequest: Decodable {
        /// Knob detents: each one moves the volume by `TVThingEngine.volumeStep`.
        var steps: Int?
        /// An absolute level, 0–1.
        var level: Float?
    }

    struct MuteRequest: Decodable {
        /// Omit to toggle.
        var muted: Bool?
    }

    struct Session: Encodable {
        var id: String
        var playlist: String
    }

    struct ChannelInfo: Encodable {
        var id: UUID
        var number: Int
        var name: String
        var favorite: Int?
    }

    struct TuneRequest: Decodable {
        var channel: UUID?
        var favorite: Int?
        var step: Int?
    }

    struct FavoriteRequest: Decodable {
        var slot: Int
        /// Defaults to the channel on air.
        var channel: UUID?
    }

    struct SyncReport: Decodable {
        var session: String
        /// Program-date-time of the frame on screen, in Unix milliseconds.
        var position: Double?
        var playing: Bool
        /// Increments each time the Car Thing (re)starts the stream; older clients omit it.
        var generation: Int?
        /// False while the picture is hidden (tuning or a recovery blackout).
        var visible: Bool?
    }

    struct LogRequest: Decodable {
        var message: String
    }

    struct Health: Encodable {
        var app = "TV Thing"
        var version: String
        var api = DeviceAPI.version
    }

    struct OK: Encodable {
        var ok = true
    }
}
