import Foundation

/// The user's channel lineup: an ordered list, four favorite slots mapped to the
/// Car Thing's preset buttons, and the channel currently on air.
///
/// A value type with no I/O so it can be reasoned about and tested in isolation.
public struct ChannelLibrary: Codable, Equatable, Sendable {
    public static let favoriteSlotCount = 4

    public private(set) var channels: [Channel]
    public private(set) var favorites: [Channel.ID?]
    public private(set) var currentChannelID: Channel.ID?

    public init(channels: [Channel] = [], favorites: [Channel.ID?] = [], currentChannelID: Channel.ID? = nil) {
        self.channels = channels
        self.favorites = favorites
        self.currentChannelID = currentChannelID
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = try container.decodeIfPresent([Channel].self, forKey: .channels) ?? []
        favorites = try container.decodeIfPresent([Channel.ID?].self, forKey: .favorites) ?? []
        currentChannelID = try container.decodeIfPresent(Channel.ID.self, forKey: .currentChannelID)
        normalize()
    }

    // MARK: Queries

    public var currentChannel: Channel? { currentChannelID.flatMap(channel(withID:)) }

    public func channel(withID id: Channel.ID) -> Channel? {
        channels.first { $0.id == id }
    }

    /// One-based position used as the on-screen channel number.
    public func number(of id: Channel.ID) -> Int? {
        channels.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    public func favorite(at slot: Int) -> Channel? {
        guard favorites.indices.contains(slot), let id = favorites[slot] else { return nil }
        return channel(withID: id)
    }

    public func favoriteSlot(of id: Channel.ID) -> Int? {
        favorites.firstIndex(of: id)
    }

    /// The channel `step` positions away from the current one, wrapping around the list.
    public func channel(steppingBy step: Int) -> Channel? {
        guard !channels.isEmpty else { return nil }
        guard let id = currentChannelID, let index = channels.firstIndex(where: { $0.id == id }) else {
            return channels.first
        }
        let count = channels.count
        return channels[((index + step) % count + count) % count]
    }

    // MARK: Mutations

    public mutating func add(_ channel: Channel) {
        channels.append(channel)
        normalize()
    }

    public mutating func add(contentsOf newChannels: [Channel]) {
        channels.append(contentsOf: newChannels)
        normalize()
    }

    /// Adds only channels whose source isn't already in the lineup (or earlier in
    /// `newChannels`), and returns the ones added.
    @discardableResult
    public mutating func merge(_ newChannels: [Channel]) -> [Channel] {
        var known = Set(channels.map(\.source))
        let added = newChannels.filter { known.insert($0.source).inserted }
        add(contentsOf: added)
        return added
    }

    public mutating func update(_ channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index] = channel
    }

    public mutating func remove(ids: Set<Channel.ID>) {
        channels.removeAll { ids.contains($0.id) }
        normalize()
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { channels[$0] }
        var remaining = channels.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertion, remaining.count)))
        channels = remaining
    }

    /// Assigns a channel to a favorite slot. A channel occupies at most one slot.
    public mutating func setFavorite(_ id: Channel.ID?, at slot: Int) {
        guard favorites.indices.contains(slot) else { return }
        if let id {
            guard channel(withID: id) != nil else { return }
            for index in favorites.indices where favorites[index] == id { favorites[index] = nil }
        }
        favorites[slot] = id
    }

    public mutating func setCurrentChannel(_ id: Channel.ID?) {
        guard let id else { currentChannelID = nil; return }
        if channel(withID: id) != nil { currentChannelID = id }
    }

    /// Keeps invariants: exactly four favorite slots, no dangling references, and a current
    /// channel whenever the list isn't empty.
    private mutating func normalize() {
        let known = Set(channels.map(\.id))
        favorites = (0..<Self.favoriteSlotCount).map { slot in
            guard favorites.indices.contains(slot), let id = favorites[slot], known.contains(id) else { return nil }
            return id
        }
        if let id = currentChannelID, !known.contains(id) { currentChannelID = nil }
        if currentChannelID == nil { currentChannelID = channels.first?.id }
    }
}
