import Foundation
import Network
import os

/// A minimal HTTP/1.1 server bound to the loopback interface.
///
/// Serves one request per connection, which is all the Car Thing (via Bridgething),
/// AVPlayer, and FFmpeg need. Handlers are async and run off the network queue.
public final class LocalHTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum State: Equatable, Sendable {
        case starting
        case ready
        case failed(String)
    }

    private static let maximumRequestSize = 1 << 20

    public let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "TVThing.LocalHTTPServer", qos: .userInitiated)
    private let listener = OSAllocatedUnfairLock<NWListener?>(initialState: nil)

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    public func start(onStateChange: @escaping @Sendable (State) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let port = self.port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onStateChange(.ready)
            case .failed(let error), .waiting(let error):
                if case .posix(.EADDRINUSE) = error {
                    onStateChange(.failed("Port \(port) is in use. Quit any other copy of TV Thing (or other app using this port) and relaunch."))
                } else {
                    onStateChange(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        self.listener.withLock { $0 = listener }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connection handling

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maximumRequestSize {
                Self.send(.error("Request too large", status: 413), on: connection)
            } else if let request = Self.parse(buffer) {
                if let rejection = self.reject(request) {
                    Self.send(rejection, on: connection)
                    return
                }
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Keeps web pages in the user's browser from driving the server: DNS-rebinding
    /// requests carry a foreign `Host`, and cross-site form posts can't send JSON
    /// without a CORS preflight, which this server never approves.
    private func reject(_ request: HTTPRequest) -> HTTPResponse? {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        if let host = request.headers["host"], !allowedHosts.contains(host.lowercased()) {
            return .error("Forbidden host", status: 400)
        }
        if request.method == "POST", request.headers["content-type"]?.hasPrefix("application/json") != true {
            return .error("Expected application/json", status: 400)
        }
        return nil
    }

    /// Returns a request once the head and the full body have arrived, otherwise `nil`.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= bodyLength else { return nil }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.percentEncodedPath ?? target,
            query: query,
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + bodyLength)])
        )
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.status) \(response.reasonPhrase)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
