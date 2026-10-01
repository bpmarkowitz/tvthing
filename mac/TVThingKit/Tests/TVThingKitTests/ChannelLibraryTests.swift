import Foundation
import Testing
@testable import TVThingKit

private func channel(_ name: String) -> Channel {
    Channel(name: name, source: .init(provider: .hls, value: "https://example.com/\(name).m3u8"))
}

@Suite struct ChannelLibraryTests {
    @Test func alwaysHasFourFavoriteSlotsAndACurrentChannel() {
        var library = ChannelLibrary()
        #expect(library.favorites == [nil, nil, nil, nil])
        #expect(library.currentChannelID == nil)

        let news = channel("news")
        library.add(news)
        #expect(library.currentChannelID == news.id)
    }

    @Test func removingAChannelClearsItsFavoriteAndMovesOffIt() {
        let a = channel("a"), b = channel("b")
        var library = ChannelLibrary(channels: [a, b], currentChannelID: a.id)
        library.setFavorite(a.id, at: 2)
        library.remove(ids: [a.id])
        #expect(library.favorites[2] == nil)
        #expect(library.currentChannelID == b.id)
    }

    @Test func aChannelOccupiesOnlyOneFavoriteSlot() {
        let a = channel("a")
        var library = ChannelLibrary(channels: [a])
        library.setFavorite(a.id, at: 0)
        library.setFavorite(a.id, at: 3)
        #expect(library.favorites == [nil, nil, nil, a.id])
    }

    @Test func steppingWrapsAroundTheList() {
        let a = channel("a"), b = channel("b"), c = channel("c")
        let library = ChannelLibrary(channels: [a, b, c], currentChannelID: a.id)
        #expect(library.channel(steppingBy: 1)?.id == b.id)
        #expect(library.channel(steppingBy: -1)?.id == c.id)
        #expect(library.channel(steppingBy: 4)?.id == b.id)
    }

    @Test func movingChannelsMatchesSwiftUISemantics() {
        let a = channel("a"), b = channel("b"), c = channel("c")
        var library = ChannelLibrary(channels: [a, b, c])
        library.move(fromOffsets: [0], toOffset: 3)
        #expect(library.channels.map(\.name) == ["b", "c", "a"])
        library.move(fromOffsets: [2], toOffset: 0)
        #expect(library.channels.map(\.name) == ["a", "b", "c"])
    }

    @Test func mergeSkipsChannelsAlreadyInTheLineup() {
        let a = channel("a"), b = channel("b")
        var library = ChannelLibrary(channels: [a])
        let added = library.merge([channel("a"), b, channel("b")])
        #expect(added.map(\.id) == [b.id])
        #expect(library.channels.map(\.name) == ["a", "b"])
    }

    @Test func decodingRepairsInvalidState() throws {
        let json = #"{"channels":[],"favorites":["00000000-0000-0000-0000-000000000000"],"currentChannelID":"00000000-0000-0000-0000-000000000000"}"#
        let library = try JSONDecoder().decode(ChannelLibrary.self, from: Data(json.utf8))
        #expect(library.favorites == [nil, nil, nil, nil])
        #expect(library.currentChannelID == nil)
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tvthing-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(fileURL: url)
        #expect(try store.load() == nil)
        let library = ChannelLibrary(channels: [channel("a"), channel("b")])
        try store.save(library)
        #expect(try store.load() == library)
    }
}

@Suite struct ChannelPackTests {
    @Test func roundTripsAndOmitsDefaultPlayback() throws {
        var convert = channel("b")
        convert.playback = .convert
        let data = try ChannelPack(name: "Test", exporting: [channel("a"), convert]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"tvthing.channels\""))
        #expect(text.components(separatedBy: "playback").count == 2)

        let decoded = try ChannelPack.decode(data)
        #expect(decoded.name == "Test")
        #expect(decoded.makeChannels().map(\.playback) == [.automatic, .convert])
    }

    @Test func acceptsURLShorthand() throws {
        let json = #"{"format":"tvthing.channels","version":1,"channels":[{"name":"News","url":"https://example.com/news.m3u8"}]}"#
        let pack = try ChannelPack.decode(Data(json.utf8))
        #expect(pack.channels.first?.source == SourceReference(provider: .hls, value: "https://example.com/news.m3u8"))
    }

    @Test func rejectsNewerVersionsAndForeignJSON() {
        let newer = #"{"format":"tvthing.channels","version":99,"channels":[]}"#
        #expect(throws: ChannelPackError.unsupportedVersion(99)) { try ChannelPack.decode(Data(newer.utf8)) }
        #expect(throws: ChannelPackError.unreadable) { try ChannelPack.decode(Data(#"{"hello":1}"#.utf8)) }
    }

    @Test func parsesExtendedM3U() throws {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-name="Fallback" group-title="News, Weather",Channel One
        https://example.com/one/master.m3u8
        #EXTINF:-1 tvg-name="Two",
        https://example.com/two.m3u8
        rtmp://example.com/ignored
        https://example.com/three/playlist.m3u8
        """
        let pack = try ChannelPack.decode(Data(m3u.utf8))
        #expect(pack.channels.map(\.name) == ["Channel One", "Two", "playlist"])
    }
}
