import Darwin
import Foundation

final class LocalHTTPServer: @unchecked Sendable {
    private(set) var port: UInt16

    private let handler: MCPProtocolHandler
    private let acceptQueue = DispatchQueue(label: "memorybar.http.accept")
    private let workerQueue = DispatchQueue(label: "memorybar.http.worker", attributes: .concurrent)
    private var listeningSocket: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: UInt16, handler: MCPProtocolHandler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard listeningSocket == -1 else { return }
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw HTTPServerError.system("socket") }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw HTTPServerError.system("bind 127.0.0.1:\(port)")
        }
        if port == 0 {
            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socketFD, $0, &boundLength)
                }
            }
            if result == 0 { port = UInt16(bigEndian: boundAddress.sin_port) }
        }
        guard Darwin.listen(socketFD, 16) == 0 else {
            Darwin.close(socketFD)
            throw HTTPServerError.system("listen")
        }
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        listeningSocket = socketFD

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { Darwin.close(socketFD) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        listeningSocket = -1
    }

    deinit {
        stop()
    }

    private func acceptPendingConnections() {
        while true {
            let client = Darwin.accept(listeningSocket, nil, nil)
            guard client >= 0 else { break }
            _ = fcntl(client, F_SETFL, 0)
            workerQueue.async { [weak self] in
                self?.serve(client)
                Darwin.close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        guard let request = readRequest(client) else {
            send(client, status: "400 Bad Request", contentType: "application/json", body: json(["error": "Bad request"]))
            return
        }

        if request.method == "OPTIONS" {
            send(client, status: "204 No Content", contentType: "text/plain", body: Data())
        } else if request.method == "GET", request.path == "/health" {
            send(client, status: "200 OK", contentType: "application/json", body: json([
                "status": "ok",
                "service": "MemoryBar",
                "mcp": "http://127.0.0.1:\(port)/mcp"
            ]))
        } else if request.method == "POST", request.path == "/mcp" {
            if let response = handler.handle(request.body) {
                send(client, status: "200 OK", contentType: "application/json", body: response)
            } else {
                send(client, status: "202 Accepted", contentType: "application/json", body: Data())
            }
        } else {
            send(client, status: "404 Not Found", contentType: "application/json", body: json([
                "error": "Use POST /mcp or GET /health"
            ]))
        }
    }

    private func readRequest(_ client: Int32) -> HTTPRequest? {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        let delimiter = Data("\r\n\r\n".utf8)

        while data.count < 2_000_000 {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)

            if headerEnd == nil, let range = data.range(of: delimiter) {
                headerEnd = range
                let headers = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                contentLength = parseContentLength(headers)
            }
            if let headerEnd, data.count >= headerEnd.upperBound + contentLength { break }
        }

        guard let headerEnd else { return nil }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = min(data.count, bodyStart + contentLength)
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]).components(separatedBy: "?").first ?? String(parts[1]),
            body: data.subdata(in: bodyStart..<bodyEnd)
        )
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func send(_ client: Int32, status: String, contentType: String, body: Data) {
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: http://127.0.0.1\r
        Access-Control-Allow-Methods: POST, GET, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id\r
        Connection: close\r
        \r

        """
        var response = Data(headers.utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(client, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { break }
                sent += count
            }
        }
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var body: Data
}

private enum HTTPServerError: LocalizedError {
    case system(String)

    var errorDescription: String? {
        switch self {
        case .system(let operation):
            "Local MCP server could not \(operation): \(String(cString: strerror(errno)))"
        }
    }
}
