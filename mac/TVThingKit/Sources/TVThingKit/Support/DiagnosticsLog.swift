import Foundation
import os

/// A bounded, in-memory event log shown in Settings → Diagnostics, collecting messages
/// from both the Mac and the Car Thing. Also forwarded to the unified system log.
public actor DiagnosticsLog {
    public enum Source: String, Codable, Sendable {
        case mac
        case device
    }

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: Int
        public let date: Date
        public let source: Source
        public let message: String
    }

    private static let logger = Logger(subsystem: "com.tvthing", category: "diagnostics")
    private let capacity: Int
    private var entries: [Entry] = []
    private var nextID = 0

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func record(_ message: String, source: Source) {
        nextID += 1
        entries.append(Entry(id: nextID, date: .now, source: source, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        Self.logger.info("[\(source.rawValue, privacy: .public)] \(message, privacy: .public)")
    }

    public func recent() -> [Entry] {
        entries
    }

    public func clear() {
        entries.removeAll()
    }
}
