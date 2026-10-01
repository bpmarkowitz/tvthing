import Foundation

/// Finds SiliconDust HDHomeRun network tuners and reads their channel lineups.
public enum HDHomeRun {
    public struct Device: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var host: String
        public var tunerCount: Int
    }

    private struct DiscoverInfo: Decodable {
        var DeviceID: String?
        var FriendlyName: String?
        var TunerCount: Int?
    }

    private struct CloudDevice: Decodable {
        var LocalIP: String?
    }

    struct LineupEntry: Decodable {
        var GuideNumber: String
        var GuideName: String
        var URL: String
        var DRM: Int?
    }

    /// Looks for tuners via SiliconDust's discovery service, then by asking every address
    /// on the Mac's local /24 networks for an HDHomeRun's `discover.json`.
    public static func discover(http: HTTPClient = .shared) async -> [Device] {
        var hosts = Set<String>()
        if let (data, _) = try? await http.data(from: URL(string: "https://ipv4-api.hdhomerun.com/discover")!, timeout: 5),
           let devices = try? JSONDecoder().decode([CloudDevice].self, from: data) {
            hosts.formUnion(devices.compactMap(\.LocalIP))
        }
        for prefix in localSubnetPrefixes() {
            for last in 1...254 { hosts.insert("\(prefix).\(last)") }
        }
        return await withTaskGroup(of: Device?.self) { group in
            for host in hosts {
                group.addTask { await device(at: host, http: http, timeout: 1.5) }
            }
            var found: [String: Device] = [:]
            for await device in group {
                if let device { found[device.id] = device }
            }
            return found.values.sorted { $0.host < $1.host }
        }
    }

    public static func device(at host: String, http: HTTPClient = .shared, timeout: TimeInterval = 5) async -> Device? {
        guard let url = URL(string: "http://\(host)/discover.json"),
              let (data, response) = try? await http.data(from: url, timeout: timeout),
              response.statusCode == 200,
              let info = try? JSONDecoder().decode(DiscoverInfo.self, from: data),
              let id = info.DeviceID else { return nil }
        return Device(id: id, name: info.FriendlyName ?? "HDHomeRun", host: host, tunerCount: info.TunerCount ?? 0)
    }

    /// The tuner's channels as TV Thing channels, named like "3.1 ABC-HD". Encrypted
    /// (DRM) channels are skipped, since they can't be played.
    public static func channels(at host: String, http: HTTPClient = .shared) async throws -> [Channel] {
        guard let url = URL(string: "http://\(host)/lineup.json") else { throw ProviderError.unrecognizedInput }
        let (data, response) = try await http.data(from: url, timeout: 10)
        guard response.statusCode == 200 else { throw ProviderError.unavailable("The tuner at \(host) didn't return a channel lineup.") }
        return try channels(fromLineup: data)
    }

    static func channels(fromLineup data: Data) throws -> [Channel] {
        let lineup = try JSONDecoder().decode([LineupEntry].self, from: data)
        return lineup
            .filter { ($0.DRM ?? 0) == 0 }
            .map { Channel(name: "\($0.GuideNumber) \($0.GuideName)", source: .init(provider: .transportStream, value: $0.URL)) }
    }

    /// e.g. "10.0.0" for each active IPv4 interface on a private network.
    private static func localSubnetPrefixes() -> [String] {
        var prefixes = Set<String>()
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0, (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let parts = String(cString: host).split(separator: ".")
            guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) else { continue }
            let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            if isPrivate { prefixes.insert(parts.prefix(3).joined(separator: ".")) }
        }
        return Array(prefixes)
    }
}
