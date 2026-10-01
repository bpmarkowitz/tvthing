import Foundation
import Testing
@testable import TVThingKit

/// End-to-end checks against live streams. They need network access, so they only run
/// when `TVTHING_INTEGRATION=1` is set:
///
///     TVTHING_INTEGRATION=1 swift test --filter EngineIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TVTHING_INTEGRATION"] == "1"), .serialized)
struct EngineIntegrationTests {
    static let port: UInt16 = 17_901

    struct Harness {
        let engine: TVThingEngine
        let storeURL: URL

        init() async throws {
            storeURL = FileManager.default.temporaryDirectory.appending(path: "tvthing-it-\(UUID()).json")
            engine = TVThingEngine(configuration: EngineConfiguration(port: EngineIntegrationTests.port, store: LibraryStore(fileURL: storeURL)))
            await engine.start()
            try await Task.sleep(for: .milliseconds(300))
        }

        func request(_ path: String, method: String = "GET", json: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(EngineIntegrationTests.port)\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 60
            if let json {
                request.httpBody = Data(json.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }

        func state() async throws -> [String: Any] {
            let (data, _) = try await request("/api/v1/state")
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        /// Loads the session playlist, follows the first variant, and fetches a segment.
        func playThrough() async throws -> (playlist: String, segmentBytes: Int) {
            let session = try await state()["session"] as! [String: Any]
            let (entry, status) = try await request(session["playlist"] as! String)
            #expect(status == 200, "\(String(decoding: entry, as: UTF8.self))")
            var text = String(decoding: entry, as: UTF8.self)
            if let variant = text.split(separator: "\n").first(where: { $0.hasPrefix("/stream/") }), text.contains("#EXT-X-STREAM-INF") {
                text = String(decoding: try await request(String(variant)).0, as: UTF8.self)
            }
            let segment = try #require(text.split(separator: "\n").last(where: { $0.hasPrefix("/stream/") }))
            let (bytes, segmentStatus) = try await request(String(segment))
            #expect(segmentStatus == 200)
            return (text, bytes.count)
        }

        func shutdown() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: storeURL)
        }
    }

    @Test func relaysAStreamDirectly() async throws {
        let harness = try await Harness()
        let url = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
        await harness.engine.addChannel(Channel(name: "Bip Bop", source: .init(provider: .hls, value: url), playback: .direct))

        let (playlist, bytes) = try await harness.playThrough()
        #expect(playlist.contains("#EXTINF"))
        #expect(bytes > 10_000)
        let state = try await harness.state()
        #expect(state["phase"] as? String == "playing")
        await harness.shutdown()
    }

    @Test func convertsAStreamWithoutTimestamps() async throws {
        guard FFmpegLocator.locate() != nil else { return }
        let harness = try await Harness()
        await harness.engine.addChannel(Channel(name: "Mux test", source: .init(provider: .hls, value: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")))

        let (playlist, bytes) = try await harness.playThrough()
        #expect(playlist.contains("#EXT-X-PROGRAM-DATE-TIME"))
        #expect(bytes > 10_000)
        await harness.shutdown()
    }

    /// Needs an HDHomeRun: `TVTHING_HDHOMERUN=<ip> TVTHING_INTEGRATION=1 swift test …`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVTHING_HDHOMERUN"] != nil))
    func convertsAnHDHomeRunChannel() async throws {
        let host = ProcessInfo.processInfo.environment["TVTHING_HDHOMERUN"]!
        #expect(await HDHomeRun.discover().contains { $0.host == host })
        // Other apps (or TV Thing itself) may already be using a tuner.
        let busy = try await Self.tunersInUse(host)
        let harness = try await Harness()
        let channels = try await HDHomeRun.channels(at: host)
        #expect(!channels.isEmpty)

        // Pasting a channel URL is recognized as a broadcast stream, and the tuner is let go.
        let candidate = try await harness.engine.registry.candidate(for: channels[0].source.value)
        #expect(candidate.reference.provider == .transportStream)
        try await Task.sleep(for: .seconds(2))
        #expect(try await Self.tunersInUse(host) == busy)

        await harness.engine.importChannels([channels[0]])
        let (playlist, bytes) = try await harness.playThrough()
        #expect(playlist.contains("#EXT-X-PROGRAM-DATE-TIME"))
        #expect(bytes > 10_000)
        #expect(try await Self.tunersInUse(host) == busy + 1)

        // Stopping releases the tuner.
        await harness.shutdown()
        try await Task.sleep(for: .seconds(3))
        #expect(try await Self.tunersInUse(host) == busy)
    }

    static func tunersInUse(_ host: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://\(host)/status.json")!)
        let tuners = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return tuners.filter { $0["VctNumber"] != nil || $0["TargetIP"] != nil }.count
    }

    @Test func rejectsForeignHostsAndFormPosts() async throws {
        let harness = try await Harness()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/api/v1/tune")!)
        request.httpMethod = "POST"
        request.httpBody = Data("step=1".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 400)
        await harness.shutdown()
    }
}
