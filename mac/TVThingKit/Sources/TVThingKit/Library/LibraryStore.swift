import Foundation

/// Persists the channel library as JSON in Application Support.
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "TV Thing", directoryHint: .isDirectory)
            .appending(path: "Library.json")
    }

    /// Returns `nil` when no library has been saved yet (first launch).
    public func load() throws -> ChannelLibrary? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ChannelLibrary.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ library: ChannelLibrary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
