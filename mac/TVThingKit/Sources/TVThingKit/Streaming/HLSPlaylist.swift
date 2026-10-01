import Foundation

/// The subset of an HLS playlist TV Thing needs to judge compatibility.
struct HLSPlaylist: Equatable {
    struct Variant: Equatable {
        var uri: String
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var codecs: [String]
    }

    var variants: [Variant]
    var hasProgramDateTime: Bool
    /// A finished, on-demand video rather than a live stream.
    var hasEndList: Bool
    var segmentURIs: [String]

    var isMultivariant: Bool { !variants.isEmpty }

    init(_ text: String) {
        var variants: [Variant] = []
        var segments: [String] = []
        var pendingVariant: [String: String]?
        var hasProgramDateTime = false
        var hasEndList = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = Self.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME") {
                hasProgramDateTime = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                if let attributes = pendingVariant {
                    let size = attributes["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                    variants.append(Variant(
                        uri: line,
                        bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                        width: size?.count == 2 ? size?[0] : nil,
                        height: size?.count == 2 ? size?[1] : nil,
                        codecs: (attributes["CODECS"] ?? "")
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                    ))
                    pendingVariant = nil
                } else {
                    segments.append(line)
                }
            }
        }
        self.variants = variants
        self.hasProgramDateTime = hasProgramDateTime
        self.hasEndList = hasEndList
        self.segmentURIs = segments
    }

    /// Parses an HLS attribute list, respecting quoted values that contain commas.
    static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var quoted = false
        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""; value = ""; readingValue = false
        }
        for character in list {
            switch character {
            case "=" where !readingValue: readingValue = true
            case "\"" where readingValue: quoted.toggle()
            case "," where !quoted: commit()
            default:
                if readingValue { value.append(character) } else { key.append(character) }
            }
        }
        commit()
        return result
    }
}

/// Whether the Car Thing's player can take a stream as-is, and why not if it can't.
public enum StreamCompatibility: Equatable, Sendable {
    case direct
    case needsConversion(reason: String)
}

/// Decides whether a stream can be relayed untouched.
///
/// The Car Thing decodes H.264 comfortably up to 720p, and the Mac's audio is aligned to
/// the Car Thing's video with `EXT-X-PROGRAM-DATE-TIME` stamps, so a stream needs those
/// too. Each segment also crosses Bridgething's USB link as a single message, and large
/// ones make the link drop, so segments must stay small. Anything else goes through
/// FFmpeg, which produces small, timestamped 800×480 segments.
enum CompatibilityProbe {
    static let maximumDirectHeight = 720
    /// ~300 KB segments are proven safe; ~775 KB ones (720p, 6 s) drop the link.
    static let maximumSegmentBytes = 500_000

    /// - Parameter segmentBytes: the size of a sample segment from the variant the Car Thing will play.
    static func evaluate(multivariant: HLSPlaylist?, media: HLSPlaylist, segmentBytes: Int? = nil) -> StreamCompatibility {
        if let multivariant {
            let candidates = multivariant.variants.filter(isPlayable)
            guard !candidates.isEmpty else {
                return .needsConversion(reason: "Uses a video codec the Car Thing can't decode")
            }
            if let smallest = candidates.compactMap(\.height).min(), smallest > maximumDirectHeight {
                return .needsConversion(reason: "Every quality level is above \(maximumDirectHeight)p")
            }
        }
        guard media.hasProgramDateTime else {
            return .needsConversion(reason: "No timestamps to sync Mac audio with")
        }
        if let segmentBytes, segmentBytes > maximumSegmentBytes {
            return .needsConversion(reason: "Video chunks are too large for the Car Thing link (\(segmentBytes / 1_000) KB)")
        }
        return .direct
    }

    /// The variant to convert when FFmpeg is needed, as its index among all variants
    /// (FFmpeg's program number): the best one up to 720p, which converts cleanly to 800×480.
    static func conversionVariant(in playlist: HLSPlaylist) -> Int? {
        let video = playlist.variants.enumerated().filter { $0.element.codecs.isEmpty || $0.element.codecs.contains { !$0.hasPrefix("mp4a") } }
        let fitting = video.filter { ($0.element.height ?? 0) <= maximumDirectHeight }
        let pick = fitting.max { $0.element.bandwidth < $1.element.bandwidth } ?? video.min { $0.element.bandwidth < $1.element.bandwidth }
        return pick?.offset
    }

    /// The variant the Car Thing will play: the lowest-bandwidth playable one.
    static func preferredVariant(in playlist: HLSPlaylist) -> HLSPlaylist.Variant? {
        playlist.variants.filter(isPlayable).min { $0.bandwidth < $1.bandwidth }
    }

    private static func isPlayable(_ variant: HLSPlaylist.Variant) -> Bool {
        guard !variant.codecs.isEmpty else { return true }
        let audioPrefixes = ["mp4a", "ac-3", "ec-3", "opus", "flac"]
        let videoCodecs = variant.codecs.filter { codec in !audioPrefixes.contains { codec.hasPrefix($0) } }
        return !videoCodecs.isEmpty && videoCodecs.allSatisfy { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") }
    }
}
