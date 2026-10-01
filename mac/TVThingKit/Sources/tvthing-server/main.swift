import Foundation
import TVThingKit

// Runs the TV Thing engine without the Mac app, for Car Thing development:
//
//     swift run tvthing-server [--port 17839] [--pack channels.tvthing] [--library path.json]
//
// There is no companion audio; the Car Thing (or a browser via `npm run dev`) plays video.

setvbuf(stdout, nil, _IOLBF, 0)

var port: UInt16 = 17_839
var packURL: URL?
var libraryURL = FileManager.default.temporaryDirectory.appending(path: "tvthing-server-library.json")

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port": port = arguments.next().flatMap(UInt16.init) ?? port
    case "--pack": packURL = arguments.next().map { URL(fileURLWithPath: $0) }
    case "--library": libraryURL = arguments.next().map { URL(fileURLWithPath: $0) } ?? libraryURL
    default:
        print("Usage: tvthing-server [--port N] [--pack FILE] [--library FILE]")
        exit(64)
    }
}

let engine = TVThingEngine(configuration: EngineConfiguration(port: port, store: LibraryStore(fileURL: libraryURL), appVersion: "dev"))
if let packURL {
    let result = try await engine.importChannels(from: Data(contentsOf: packURL))
    print("Imported \(result.added) channels from \(packURL.lastPathComponent)")
}
await engine.start()
print("TV Thing engine on http://127.0.0.1:\(port) (library: \(libraryURL.path))")

Task {
    var printed = 0
    while true {
        let entries = await engine.log.recent()
        for entry in entries.dropFirst(printed) { print("[\(entry.source.rawValue)] \(entry.message)") }
        printed = entries.count
        try? await Task.sleep(for: .seconds(1))
    }
}

for await snapshot in engine.snapshots {
    if case .failed(let message) = snapshot.server {
        print("Server failed: \(message)")
        exit(1)
    }
}
