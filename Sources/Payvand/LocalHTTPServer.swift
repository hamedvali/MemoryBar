import Darwin
import Foundation

final class LocalHTTPServer: @unchecked Sendable {
    private(set) var port: UInt16

    private let handler: MCPProtocolHandler
    private let authorization: MCPAuthorizationService
    private let acceptQueue = DispatchQueue(label: "payvand.http.accept")
    private let workerQueue = DispatchQueue(label: "payvand.http.worker", attributes: .concurrent)
    private var listeningSocket: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: UInt16, handler: MCPProtocolHandler, authorization: MCPAuthorizationService) {
        self.port = port
        self.handler = handler
        self.authorization = authorization
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
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        guard let request = readRequest(client) else {
            // Browsers and MCP clients may open speculative loopback connections
            // and leave them idle. Closing an empty/timed-out socket quietly lets
            // the client retry; sending an unsolicited 400 can be surfaced as the
            // result of a later OAuth button click.
            return
        }

        guard isTrustedHost(request.headers["host"]), isTrustedOrigin(for: request) else {
            send(client, status: "403 Forbidden", contentType: "application/json", body: json([
                "error": "Untrusted request origin"
            ]), request: request)
            return
        }

        if request.method == "OPTIONS" {
            send(client, status: "204 No Content", contentType: "text/plain", body: Data(), request: request)
        } else if request.method == "GET", request.path == "/health" {
            send(client, status: "200 OK", contentType: "application/json", body: json([
                "status": "ok",
                "service": "Payvand",
                "mcp": "http://127.0.0.1:\(port)/mcp",
                "authorization": "oauth2"
            ]), request: request)
        } else if request.method == "GET", request.path == "/.well-known/oauth-protected-resource" {
            sendOAuthJSON(client, status: "200 OK", value: authorization.protectedResourceMetadata, request: request)
        } else if request.method == "GET", request.path == "/.well-known/oauth-protected-resource/mcp" {
            sendOAuthJSON(client, status: "200 OK", value: authorization.protectedResourceMetadata, request: request)
        } else if request.method == "GET", request.path == "/.well-known/oauth-authorization-server" {
            sendOAuthJSON(client, status: "200 OK", value: authorization.authorizationServerMetadata, request: request)
        } else if request.method == "POST", request.path == "/register" {
            registerClient(client, request: request)
        } else if request.method == "GET", request.path == "/authorize" {
            authorizeClient(client, request: request)
        } else if request.method == "POST", request.path == "/authorize/decision" {
            completeAuthorization(client, request: request)
        } else if request.method == "POST", request.path == "/token" {
            exchangeToken(client, request: request)
        } else if request.method == "POST", request.path == "/mcp" {
            guard let context = authorization.authenticate(authorizationHeader: request.headers["authorization"]) else {
                send(client, status: "401 Unauthorized", contentType: "application/json", body: json([
                    "error": "unauthorized",
                    "error_description": "Authorize this MCP client before accessing work memory."
                ]), extraHeaders: [
                    "WWW-Authenticate": "Bearer resource_metadata=\"\(authorization.baseURL)/.well-known/oauth-protected-resource\""
                ], request: request)
                return
            }
            if let requiredScope = handler.requiredScope(for: request.body), !context.scopes.contains(requiredScope) {
                send(client, status: "403 Forbidden", contentType: "application/json", body: json([
                    "error": "insufficient_scope",
                    "error_description": "This client is not authorized for \(requiredScope)."
                ]), extraHeaders: [
                    "WWW-Authenticate": "Bearer scope=\"\(requiredScope)\""
                ], request: request)
                return
            }
            if let response = handler.handle(request.body, authorization: context) {
                send(client, status: "200 OK", contentType: "application/json", body: response, request: request)
            } else {
                send(client, status: "202 Accepted", contentType: "application/json", body: Data(), request: request)
            }
        } else if request.method == "GET", request.path == "/mcp" {
            send(client, status: "405 Method Not Allowed", contentType: "application/json", body: json([
                "error": "This local MCP server does not expose an SSE stream. Use POST /mcp."
            ]), extraHeaders: ["Allow": "POST"], request: request)
        } else {
            send(client, status: "404 Not Found", contentType: "application/json", body: json([
                "error": "Not found"
            ]), request: request)
        }
    }

    private func registerClient(_ client: Int32, request: HTTPRequest) {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = payload["client_name"] as? String,
                  let redirects = payload["redirect_uris"] as? [String] else {
                throw MCPAuthorizationError.invalidRequest("client_name and redirect_uris are required.")
            }
            if let method = payload["token_endpoint_auth_method"] as? String, method != "none" {
                throw MCPAuthorizationError.invalidRequest("Local public clients must use token_endpoint_auth_method=none and PKCE.")
            }
            let registration = try authorization.registerClient(name: name, redirectURIs: redirects)
            sendOAuthJSON(client, status: "201 Created", value: [
                "client_id": registration.clientID,
                "client_name": registration.clientName,
                "redirect_uris": registration.redirectURIs,
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
                "client_id_issued_at": Int(Date().timeIntervalSince1970)
            ], request: request)
        } catch {
            sendOAuthError(client, error: error, status: "400 Bad Request", request: request)
        }
    }

    private func authorizeClient(_ client: Int32, request: HTTPRequest) {
        do {
            let prompt = try authorization.prepareAuthorization(request.query)
            send(client, status: "200 OK", contentType: "text/html; charset=utf-8", body: authorization.authorizationPage(for: prompt), extraHeaders: [
                "Cache-Control": "no-store",
                "Content-Security-Policy": prompt.contentSecurityPolicy,
                "Referrer-Policy": "no-referrer",
                "X-Frame-Options": "DENY",
                "X-Content-Type-Options": "nosniff"
            ], request: request)
        } catch {
            sendHTMLMessage(client, status: "400 Bad Request", title: "Authorization failed", message: error.localizedDescription, request: request)
        }
    }

    private func completeAuthorization(_ client: Int32, request: HTTPRequest) {
        do {
            let form = parseURLEncoded(request.body)
            guard let requestID = form["request_id"] else {
                throw MCPAuthorizationError.invalidRequest("The authorization request is missing.")
            }
            guard let destination = try authorization.completeAuthorization(
                requestID: requestID,
                approved: form["decision"] == "allow"
            ) else {
                sendHTMLMessage(
                    client,
                    status: "200 OK",
                    title: "Authorization already completed",
                    message: "You can close this window and return to your MCP client.",
                    request: request
                )
                return
            }
            send(client, status: "303 See Other", contentType: "text/html; charset=utf-8", body: Data("Authorization complete. You can close this window.".utf8), extraHeaders: [
                "Location": destination.absoluteString,
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer"
            ], request: request)
        } catch {
            sendHTMLMessage(client, status: "400 Bad Request", title: "Authorization failed", message: error.localizedDescription, request: request)
        }
    }

    private func exchangeToken(_ client: Int32, request: HTTPRequest) {
        do {
            let token = try authorization.exchangeToken(parseURLEncoded(request.body))
            sendOAuthJSON(client, status: "200 OK", value: token.dictionary, request: request)
        } catch let error as MCPAuthorizationError {
            let status = error.oauthCode == "invalid_client" ? "401 Unauthorized" : "400 Bad Request"
            sendOAuthError(client, error: error, status: status, request: request)
        } catch {
            sendOAuthError(client, error: error, status: "500 Internal Server Error", request: request)
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
            if count < 0, errno == EINTR { continue }
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
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2 {
                headers[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetParts[0])
        let query = targetParts.count == 2 ? parseURLEncoded(Data(targetParts[1].utf8)) : [:]
        return HTTPRequest(
            method: String(parts[0]),
            path: path,
            query: query,
            headers: headers,
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

    private func send(
        _ client: Int32,
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        request: HTTPRequest? = nil
    ) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Methods: POST, GET, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type, Accept, Authorization, MCP-Protocol-Version, MCP-Session-Id",
            "Connection: close"
        ]
        if let request, let origin = request.headers["origin"], Self.isLoopbackOrigin(origin) {
            headers.append("Access-Control-Allow-Origin: \(origin)")
            headers.append("Vary: Origin")
        }
        for (name, value) in extraHeaders {
            let safeName = name.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            let safeValue = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            headers.append("\(safeName): \(safeValue)")
        }
        let headerLines = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(headerLines.utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(client, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
        }
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }

    private func sendOAuthJSON(_ client: Int32, status: String, value: [String: Any], request: HTTPRequest) {
        send(client, status: status, contentType: "application/json", body: json(value), extraHeaders: [
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "X-Content-Type-Options": "nosniff"
        ], request: request)
    }

    private func sendOAuthError(_ client: Int32, error: Error, status: String, request: HTTPRequest) {
        let oauth = error as? MCPAuthorizationError
        sendOAuthJSON(client, status: status, value: [
            "error": oauth?.oauthCode ?? "server_error",
            "error_description": error.localizedDescription
        ], request: request)
    }

    private func sendHTMLMessage(_ client: Int32, status: String, title: String, message: String, request: HTTPRequest) {
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(htmlEscape(title))</title></head><body style="font:16px -apple-system;padding:40px;max-width:640px;margin:auto">
        <h1>\(htmlEscape(title))</h1><p>\(htmlEscape(message))</p></body></html>
        """
        send(client, status: status, contentType: "text/html; charset=utf-8", body: Data(body.utf8), extraHeaders: [
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            "X-Frame-Options": "DENY"
        ], request: request)
    }

    private func parseURLEncoded(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var values: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first else { continue }
            let rawValue = pieces.count == 2 ? String(pieces[1]) : ""
            let name = String(rawName).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawName)
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            values[name] = value
        }
        return values
    }

    private func isTrustedHost(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let host = value.split(separator: ":", maxSplits: 1).first?.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    private func isTrustedOrigin(for request: HTTPRequest) -> Bool {
        Self.isTrustedOrigin(
            method: request.method,
            path: request.path,
            origin: request.headers["origin"]
        )
    }

    static func isTrustedOrigin(method: String, path: String, origin: String?) -> Bool {
        guard let origin else { return true }
        if isLoopbackOrigin(origin) { return true }

        // Safari can serialize a local, top-level form submission with the opaque
        // `null` origin. This exception is intentionally limited to the approval
        // endpoint: the form also carries an unguessable, one-time request ID,
        // which is consumed by completeAuthorization before a code is issued.
        return method == "POST"
            && path == "/authorize/decision"
            && origin.caseInsensitiveCompare("null") == .orderedSame
    }

    private static func isLoopbackOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
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
