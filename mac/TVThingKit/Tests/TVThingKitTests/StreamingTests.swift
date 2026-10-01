import Foundation
import Testing
@testable import TVThingKit

@Suite struct HLSPlaylistTests {
    static let multivariant = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
    hi/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
    lo/index.m3u8
    """

    static let media = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-PROGRAM-DATE-TIME:2026-09-30T12:00:00.000Z
    #EXTINF:6.0,
    seg1.ts
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k?id=1"
    #EXTINF:6.0,
    seg2.ts
    """

    @Test func parsesVariantsWithQuotedCommas() {
        let playlist = HLSPlaylist(Self.multivariant)
        #expect(playlist.variants.count == 2)
        #expect(playlist.variants[1].codecs == ["avc1.4d401e", "mp4a.40.2"])
        #expect(playlist.variants[1].height == 360)
        #expect(CompatibilityProbe.preferredVariant(in: playlist)?.uri == "lo/index.m3u8")
    }

    @Test func directWhenH264AndTimestamped() {
        let verdict = CompatibilityProbe.evaluate(multivariant: HLSPlaylist(Self.multivariant), media: HLSPlaylist(Self.media))
        #expect(verdict == .direct)
    }

    @Test func convertsWithoutProgramDateTime() {
        let media = HLSPlaylist("#EXTM3U\n#EXTINF:6,\na.ts")
        guard case .needsConversion = CompatibilityProbe.evaluate(multivariant: nil, media: media) else {
            Issue.record("Expected conversion"); return
        }
    }

    @Test func convertsStreamsWithLargeSegments() {
        let media = HLSPlaylist(Self.media)
        #expect(CompatibilityProbe.evaluate(multivariant: nil, media: media, segmentBytes: 290_000) == .direct)
        #expect(CompatibilityProbe.evaluate(multivariant: nil, media: media, segmentBytes: 775_000) != .direct)
    }

    @Test func convertsHEVCAndLargeOnlyStreams() {
        let hevc = HLSPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"hvc1.1.6.L93.B0,mp4a.40.2\"\na.m3u8")
        let large = HLSPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080,CODECS=\"avc1.640028\"\na.m3u8")
        let audioOnly = HLSPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"mp4a.40.2\"\na.m3u8")
        let media = HLSPlaylist(Self.media)
        for playlist in [hevc, large, audioOnly] {
            #expect(CompatibilityProbe.evaluate(multivariant: playlist, media: media) != .direct)
        }
    }
}

@Suite struct HLSRelayTests {
    @Test func rewritesEveryURIToLocalTokens() async {
        let base = URL(string: "https://cdn.example.com/live/lo/index.m3u8")!
        let relay = HLSRelay(mediaPrefix: "/stream/abc/s/", upstream: .init(entryURL: base, prepare: { _ in }), http: .shared, onUnauthorized: { nil })
        let output = await relay.rewrite(HLSPlaylistTests.media, base: base)
        let lines = output.components(separatedBy: "\n")
        #expect(lines.contains("/stream/abc/s/1.ts"))
        #expect(lines.contains("/stream/abc/s/3.ts"))
        #expect(output.contains(#"URI="/stream/abc/s/2""#))
        #expect(output.contains("#EXT-X-PROGRAM-DATE-TIME:2026-09-30T12:00:00.000Z"))
        // The same upstream URL keeps the same token.
        #expect(await relay.rewrite("seg1.ts", base: base) == "/stream/abc/s/1.ts")
    }
}

@Suite struct HTTPParsingTests {
    @Test func waitsForTheFullBody() {
        let head = "POST /api/v1/sync?x=1 HTTP/1.1\r\nHost: 127.0.0.1:17839\r\nContent-Length: 4\r\n\r\n"
        #expect(LocalHTTPServer.parse(Data((head + "ab").utf8)) == nil)
        let request = LocalHTTPServer.parse(Data((head + "abcd").utf8))
        #expect(request?.method == "POST")
        #expect(request?.pathComponents == ["api", "v1", "sync"])
        #expect(request?.query["x"] == "1")
        #expect(request?.headers["host"] == "127.0.0.1:17839")
        #expect(request?.body == Data("abcd".utf8))
    }
}

@Suite struct SyncPolicyTests {
    @Test func alignsOnceThenHoldsThroughJitter() {
        var policy = SyncPolicy()
        #expect(policy.evaluate(difference: 1.5, offsetMs: 0) == .seek(by: 1.5, reason: .initial))
        for jitter in [0.2, -0.15, 0.3, -0.2] {
            #expect(policy.evaluate(difference: jitter, offsetMs: 0) == .none)
        }
    }

    @Test func realignsAfterASustainedJump() {
        var policy = SyncPolicy()
        let start = Date.now
        _ = policy.evaluate(difference: 0, offsetMs: 0, now: start)
        #expect(policy.evaluate(difference: 2, offsetMs: 0, now: start.addingTimeInterval(6)) == .none)
        #expect(policy.evaluate(difference: 2, offsetMs: 0, now: start.addingTimeInterval(6.4)) == .seek(by: 2, reason: .transition))
    }

    @Test func realignsWhenTheOffsetChanges() {
        var policy = SyncPolicy()
        _ = policy.evaluate(difference: 0, offsetMs: 0)
        #expect(policy.evaluate(difference: 0.3, offsetMs: 100) == .seek(by: 0.3, reason: .offsetChanged))
    }

    @Test func correctsPersistentDrift() {
        var policy = SyncPolicy()
        _ = policy.evaluate(difference: 0, offsetMs: 0)
        var actions: [SyncPolicy.Action] = []
        for _ in 0..<SyncPolicy.driftSamples { actions.append(policy.evaluate(difference: 0.35, offsetMs: 0)) }
        #expect(actions.dropLast().allSatisfy { $0 == .none })
        #expect(actions.last == .seek(by: 0.35, reason: .drift))
    }
}

@Suite struct ProviderTests {
    @Test func routesInputToTheRightProvider() {
        let hls = HLSProvider()
        #expect(hls.accepts("https://example.com/live.m3u8"))
        #expect(!hls.accepts("not a url"))
    }

    @Test func suggestsReadableNames() {
        #expect(HLSProvider.suggestedName(for: URL(string: "https://x.com/hls/evening-news/master.m3u8")!) == "Evening News")
        #expect(HLSProvider.suggestedName(for: URL(string: "https://x.com/classic_movies-hd/index.m3u8")!) == "Classic Movies Hd")
    }
}
