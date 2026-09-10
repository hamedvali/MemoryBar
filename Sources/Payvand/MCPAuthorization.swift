import CryptoKit
import Foundation
import Security
import SQLite3

enum MCPMemoryScope {
    static let search = "memory:search"
    static let recent = "memory:recent"
    static let episodes = "memory:episodes"
    static let summary = "memory:summary"
    static let actions = "memory:actions"
    static let people = "memory:people"
    static let projects = "memory:projects"

    static let all = [search, recent, episodes, summary, actions, people, projects]

    static func required(for tool: String) -> String? {
        switch tool {
        case "search_memory": search
        case "get_recent_activity": recent
        case "get_episode": episodes
        case "get_day_summary": summary
        case "get_open_actions": actions
        case "get_person_context": people
        case "get_project_context": projects
        default: nil
        }
    }

    static func title(for scope: String) -> String {
        switch scope {
        case search: "Search work memory"
        case recent: "Read recent activity"
        case episodes: "Read episode evidence"
        case summary: "Build day summaries"
        case actions: "Read open actions"
        case people: "Read person context"
        case projects: "Read project context"
        default: scope
        }
    }
}

struct MCPAuthorizationContext: Sendable {
    let clientID: String
    let clientName: String
    let scopes: Set<String>

    func permits(tool: String) -> Bool {
        guard let scope = MCPMemoryScope.required(for: tool) else { return false }
        return scopes.contains(scope)
    }

    static let testFullAccess = MCPAuthorizationContext(
        clientID: "test-client",
        clientName: "Tests",
        scopes: Set(MCPMemoryScope.all)
    )
}

struct AuthorizedMCPClient: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let scopes: [String]
    let createdAt: Date
    let lastUsedAt: Date?
}

struct OAuthClientRegistration: Sendable {
    let clientID: String
    let clientName: String
    let redirectURIs: [String]
}

struct OAuthAuthorizationPrompt: Sendable {
    let requestID: String
    let clientName: String
    let scopes: [String]
    /// Scheme://host:port of the client's callback. The consent page must allow
    /// this origin in `form-action`: browsers enforce that directive across the
    /// whole redirect chain of a form submission, so a bare `'self'` silently
    /// swallows the 303 that carries the authorization code back to the client.
    let redirectOrigin: String

    var contentSecurityPolicy: String {
        let formAction = ["'self'", redirectOrigin]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "default-src 'none'; style-src 'unsafe-inline'; form-action \(formAction); frame-ancestors 'none'; base-uri 'none'"
    }
}

struct OAuthTokenResponse: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let scope: String

    var dictionary: [String: Any] {
        [
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": expiresIn,
            "refresh_token": refreshToken,
            "scope": scope
        ]
    }
}

enum MCPAuthorizationError: LocalizedError {
    case invalidRequest(String)
    case invalidClient
    case invalidGrant
    case invalidScope
    case unsupportedGrant
    case accessDenied
    case storage(String)
    case keychain(OSStatus)
    case secureRandom(OSStatus)

    var oauthCode: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidClient: "invalid_client"
        case .invalidGrant: "invalid_grant"
        case .invalidScope: "invalid_scope"
        case .unsupportedGrant: "unsupported_grant_type"
        case .accessDenied: "access_denied"
        case .storage, .keychain, .secureRandom: "server_error"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidClient: "The OAuth client is unknown or has been revoked."
        case .invalidGrant: "The authorization grant is invalid, expired, or already used."
        case .invalidScope: "The client requested an unsupported memory permission."
        case .unsupportedGrant: "The requested OAuth grant type is not supported."
        case .accessDenied: "The user denied access."
        case .storage(let message): "OAuth storage error: \(message)"
        case .keychain(let status): "Could not access the macOS Keychain (\(status))."
        case .secureRandom(let status): "Could not generate a secure OAuth credential (\(status))."
        }
    }
}

final class MCPAuthorizationService: @unchecked Sendable {
    static let accessTokenLifetime = 10 * 60
    static let refreshTokenLifetime = 90 * 24 * 60 * 60

    let baseURL: String
    let resourceURL: String

    private struct PendingAuthorization {
        let requestID: String
        let clientID: String
        let clientName: String
        let redirectURI: String
        let state: String?
        let codeChallenge: String
        let scopes: [String]
        let resource: String
        let expiresAt: Date
    }

    private struct AuthorizationCode {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let scopes: [String]
        let resource: String
        let expiresAt: Date
    }

    private struct CompletedAuthorization {
        let destination: URL
        let authorizationCodeDigest: String?
        let expiresAt: Date
    }

    private let lock = NSRecursiveLock()
    private let store: OAuthStore
    private let pepper: SymmetricKey
    private var pending: [String: PendingAuthorization] = [:]
    private var codes: [String: AuthorizationCode] = [:]
    private var completedAuthorizations: [String: CompletedAuthorization] = [:]

    init(storageURL: URL, port: UInt16, pepperData: Data? = nil) throws {
        baseURL = "http://127.0.0.1:\(port)"
        resourceURL = "\(baseURL)/mcp"
        let secret = try pepperData ?? LocalSecretStore.loadOrCreateTokenPepper()
        guard secret.count >= 32 else {
            throw MCPAuthorizationError.storage("The token pepper is too short.")
        }
        pepper = SymmetricKey(data: secret)
        store = try OAuthStore(url: storageURL)
        try store.removeExpiredTokens(now: Date())
    }

    var protectedResourceMetadata: [String: Any] {
        [
            "resource": resourceURL,
            "authorization_servers": [baseURL],
            "bearer_methods_supported": ["header"],
            "scopes_supported": MCPMemoryScope.all
        ]
    }

    var authorizationServerMetadata: [String: Any] {
        [
            "issuer": baseURL,
            "authorization_endpoint": "\(baseURL)/authorize",
            "token_endpoint": "\(baseURL)/token",
            "registration_endpoint": "\(baseURL)/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": MCPMemoryScope.all
        ]
    }

    func registerClient(name: String, redirectURIs: [String]) throws -> OAuthClientRegistration {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !cleanName.isEmpty, !redirectURIs.isEmpty, redirectURIs.count <= 10 else {
            throw MCPAuthorizationError.invalidRequest("A client name and at least one redirect URI are required.")
        }
        let validated = try redirectURIs.map { uri -> String in
            guard Self.isSafeRedirectURI(uri) else {
                throw MCPAuthorizationError.invalidRequest("Local MCP clients must use a loopback HTTP redirect URI.")
            }
            return uri
        }
        let client = OAuthClientRegistration(
            clientID: "payvand_\(try Self.randomToken(byteCount: 18))",
            clientName: cleanName,
            redirectURIs: Array(Set(validated)).sorted()
        )
        try store.insert(client: client, at: Date())
        return client
    }

    func prepareAuthorization(_ query: [String: String]) throws -> OAuthAuthorizationPrompt {
        try lock.withLock {
            pruneTransientState()
            guard query["response_type"] == "code",
                  let clientID = query["client_id"],
                  let redirectURI = query["redirect_uri"],
                  let codeChallenge = query["code_challenge"],
                  query["code_challenge_method"] == "S256" else {
                throw MCPAuthorizationError.invalidRequest("Authorization Code with PKCE S256 is required.")
            }
            guard codeChallenge.count >= 43, codeChallenge.count <= 128 else {
                throw MCPAuthorizationError.invalidRequest("The PKCE code challenge is invalid.")
            }
            guard let client = try store.client(id: clientID),
                  client.redirectURIs.contains(redirectURI) else {
                throw MCPAuthorizationError.invalidClient
            }
            let scopes = try requestedScopes(query["scope"])
            let resource = query["resource"] ?? resourceURL
            guard resource == resourceURL else {
                throw MCPAuthorizationError.invalidRequest("The token must be issued specifically for this MCP server.")
            }
            let requestID = try Self.randomToken(byteCount: 24)
            pending[requestID] = PendingAuthorization(
                requestID: requestID,
                clientID: clientID,
                clientName: client.clientName,
                redirectURI: redirectURI,
                state: query["state"],
                codeChallenge: codeChallenge,
                scopes: scopes,
                resource: resource,
                expiresAt: Date().addingTimeInterval(10 * 60)
            )
            return OAuthAuthorizationPrompt(
                requestID: requestID,
                clientName: client.clientName,
                scopes: scopes,
                redirectOrigin: Self.origin(of: redirectURI) ?? ""
            )
        }
    }

    func completeAuthorization(requestID: String, approved: Bool) throws -> URL? {
        try lock.withLock {
            pruneTransientState()
            if let completed = completedAuthorizations[requestID] {
                // If the browser lost the first HTTP response, replay the exact
                // same callback while its one-time code is still redeemable.
                // Once Claude has exchanged the code, a duplicate button click
                // gets the harmless "already completed" page instead.
                guard let digest = completed.authorizationCodeDigest else {
                    return completed.destination
                }
                return codes[digest] == nil ? nil : completed.destination
            }
            guard let request = pending.removeValue(forKey: requestID), request.expiresAt > Date() else {
                throw MCPAuthorizationError.invalidGrant
            }
            let completionExpiry = Date().addingTimeInterval(10 * 60)
            guard approved else {
                let destination = try redirectURL(
                    base: request.redirectURI,
                    values: ["error": "access_denied", "state": request.state]
                )
                completedAuthorizations[requestID] = CompletedAuthorization(
                    destination: destination,
                    authorizationCodeDigest: nil,
                    expiresAt: completionExpiry
                )
                return destination
            }
            let code = try Self.randomToken(byteCount: 32)
            let codeDigest = tokenDigest(code)
            codes[codeDigest] = AuthorizationCode(
                clientID: request.clientID,
                redirectURI: request.redirectURI,
                codeChallenge: request.codeChallenge,
                scopes: request.scopes,
                resource: request.resource,
                expiresAt: Date().addingTimeInterval(2 * 60)
            )
            try store.recordGrant(clientID: request.clientID, scopes: request.scopes, at: Date())
            let destination = try redirectURL(
                base: request.redirectURI,
                values: ["code": code, "state": request.state, "iss": baseURL]
            )
            completedAuthorizations[requestID] = CompletedAuthorization(
                destination: destination,
                authorizationCodeDigest: codeDigest,
                expiresAt: completionExpiry
            )
            return destination
        }
    }

    func exchangeToken(_ form: [String: String]) throws -> OAuthTokenResponse {
        try lock.withLock {
            switch form["grant_type"] {
            case "authorization_code":
                guard let rawCode = form["code"],
                      let clientID = form["client_id"],
                      let redirectURI = form["redirect_uri"],
                      let verifier = form["code_verifier"],
                      let resource = form["resource"] else {
                    throw MCPAuthorizationError.invalidRequest("The code, client_id, redirect_uri, code_verifier, and resource are required.")
                }
                guard Self.isValidPKCEVerifier(verifier), resource == resourceURL else {
                    throw MCPAuthorizationError.invalidGrant
                }
                let digest = tokenDigest(rawCode)
                guard let code = codes.removeValue(forKey: digest),
                      code.expiresAt > Date(),
                      code.clientID == clientID,
                      code.redirectURI == redirectURI,
                      Self.pkceChallenge(for: verifier) == code.codeChallenge,
                      code.resource == resourceURL,
                      try store.client(id: clientID) != nil else {
                    throw MCPAuthorizationError.invalidGrant
                }
                return try issueTokens(clientID: clientID, scopes: code.scopes, audience: code.resource)

            case "refresh_token":
                guard let rawRefreshToken = form["refresh_token"],
                      let clientID = form["client_id"],
                      let resource = form["resource"], resource == resourceURL else {
                    throw MCPAuthorizationError.invalidRequest("The refresh_token, client_id, and matching resource are required.")
                }
                let now = Date()
                guard let record = try store.consumeRefreshToken(
                    digest: tokenDigest(rawRefreshToken),
                    clientID: clientID,
                    now: now
                ), try store.client(id: clientID) != nil else {
                    throw MCPAuthorizationError.invalidGrant
                }
                return try issueTokens(clientID: clientID, scopes: record.scopes, audience: record.audience)

            default:
                throw MCPAuthorizationError.unsupportedGrant
            }
        }
    }

    func authenticate(authorizationHeader: String?) -> MCPAuthorizationContext? {
        lock.withLock {
            guard let authorizationHeader else { return nil }
            let pieces = authorizationHeader.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
            let rawToken = String(pieces[1])
            guard !rawToken.isEmpty,
                  let record = try? store.accessToken(digest: tokenDigest(rawToken), now: Date()),
                  record.audience == resourceURL else { return nil }
            try? store.touchClient(id: record.clientID, at: Date())
            return MCPAuthorizationContext(
                clientID: record.clientID,
                clientName: record.clientName,
                scopes: Set(record.scopes)
            )
        }
    }

    func authorizedClients() -> [AuthorizedMCPClient] {
        lock.withLock { (try? store.authorizedClients()) ?? [] }
    }

    func revoke(clientID: String) throws {
        try lock.withLock {
            try store.revokeClient(id: clientID, at: Date())
        }
    }

    func authorizationPage(for prompt: OAuthAuthorizationPrompt) -> Data {
        let client = Self.htmlEscape(prompt.clientName)
        let rows = prompt.scopes.map {
            "<li><span class=\"check\">&#10003;</span> \(Self.htmlEscape(MCPMemoryScope.title(for: $0)))</li>"
        }.joined()
        let page = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Authorize Payvand</title>
        <style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:radial-gradient(circle at 20% 10%,#6d8cff33,transparent 45%),radial-gradient(circle at 85% 90%,#b46cff2b,transparent 42%),#f4f5f8;color:#15161a}.card{width:min(460px,calc(100% - 32px));padding:32px;border:1px solid #ffffffaa;border-radius:28px;background:#ffffffcc;box-shadow:0 24px 70px #13203822;backdrop-filter:blur(28px)}.icon{width:58px;height:58px;display:grid;place-items:center;border-radius:17px;background:linear-gradient(145deg,#5478ff,#8857df);color:white;font-size:29px;box-shadow:0 10px 24px #674ee944}h1{font-size:27px;letter-spacing:-.5px;margin:20px 0 7px}p{color:#656872;line-height:1.45;margin:0 0 20px}ul{list-style:none;padding:0;margin:0 0 24px}li{padding:11px 0;border-bottom:1px solid #8b8f991f}.check{color:#23a35a;font-weight:700;margin-right:8px}.note{font-size:13px;color:#777b85;background:#858b9814;border-radius:13px;padding:12px;margin-bottom:22px}.actions{display:flex;gap:10px}.actions button{flex:1;border:0;border-radius:13px;padding:12px;font:600 15px -apple-system;cursor:pointer}.deny{background:#878b941f;color:inherit}.allow{background:#5a62e8;color:white}@media(prefers-color-scheme:dark){body{background:radial-gradient(circle at 20% 10%,#536ee833,transparent 45%),radial-gradient(circle at 85% 90%,#984bd52b,transparent 42%),#16171a;color:#f4f4f6}.card{background:#27282ddd;border-color:#ffffff1f;box-shadow:0 24px 70px #0008}p,.note{color:#aeb0b7}}
        </style></head><body><main class="card"><div class="icon">&#129504;</div><h1>Allow \(client)?</h1>
        <p>This application is requesting read-only access to your private work memory.</p><ul>\(rows)</ul>
        <div class="note">Only matching results are returned. Your database remains on this Mac, but returned text may be processed by the connected AI provider.</div>
        <form method="post" action="/authorize/decision"><input type="hidden" name="request_id" value="\(Self.htmlEscape(prompt.requestID))">
        <div class="actions"><button class="deny" name="decision" value="deny">Don’t Allow</button><button class="allow" name="decision" value="allow">Allow</button></div></form>
        </main></body></html>
        """
        return Data(page.utf8)
    }

    private func issueTokens(clientID: String, scopes: [String], audience: String) throws -> OAuthTokenResponse {
        let accessToken = try Self.randomToken(byteCount: 32)
        let refreshToken = try Self.randomToken(byteCount: 32)
        let now = Date()
        try store.insertAccessToken(
            digest: tokenDigest(accessToken),
            clientID: clientID,
            scopes: scopes,
            audience: audience,
            expiresAt: now.addingTimeInterval(TimeInterval(Self.accessTokenLifetime)),
            at: now
        )
        try store.insertRefreshToken(
            digest: tokenDigest(refreshToken),
            clientID: clientID,
            scopes: scopes,
            audience: audience,
            expiresAt: now.addingTimeInterval(TimeInterval(Self.refreshTokenLifetime)),
            at: now
        )
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: Self.accessTokenLifetime,
            scope: scopes.joined(separator: " ")
        )
    }

    private func requestedScopes(_ raw: String?) throws -> [String] {
        let requested = raw.map { $0.split(separator: " ").map(String.init) } ?? MCPMemoryScope.all
        let scopes = requested.isEmpty ? MCPMemoryScope.all : Array(Set(requested)).sorted()
        guard Set(scopes).isSubset(of: Set(MCPMemoryScope.all)) else {
            throw MCPAuthorizationError.invalidScope
        }
        return scopes
    }

    private func tokenDigest(_ token: String) -> String {
        let authentication = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: pepper)
        return Data(authentication).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneTransientState() {
        let now = Date()
        pending = pending.filter { $0.value.expiresAt > now }
        codes = codes.filter { $0.value.expiresAt > now }
        completedAuthorizations = completedAuthorizations.filter { $0.value.expiresAt > now }
        try? store.removeExpiredTokens(now: now)
    }

    private func redirectURL(base: String, values: [String: String?]) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw MCPAuthorizationError.invalidRequest("The redirect URI is invalid.")
        }
        var items = components.queryItems ?? []
        for (name, value) in values {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        components.queryItems = items
        guard let url = components.url else {
            throw MCPAuthorizationError.invalidRequest("The redirect URI is invalid.")
        }
        return url
    }

    static func pkceChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw MCPAuthorizationError.secureRandom(status) }
        return Data(bytes).base64URLEncodedString()
    }

    /// The serialized origin of a redirect URI, for use as a CSP source expression.
    static func origin(of value: String) -> String? {
        guard let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = url.port else { return "\(scheme)://\(bracketed)" }
        return "\(scheme)://\(bracketed):\(port)"
    }

    private static func isSafeRedirectURI(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.fragment == nil else { return false }
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isValidPKCEVerifier(_ value: String) -> Bool {
        guard value.count >= 43, value.count <= 128 else { return false }
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.unicodeScalars.allSatisfy { permitted.contains($0) }
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private struct StoredOAuthClient {
    let clientID: String
    let clientName: String
    let redirectURIs: [String]
}

private struct StoredAccessToken {
    let clientID: String
    let clientName: String
    let scopes: [String]
    let audience: String
}

private struct StoredRefreshToken {
    let scopes: [String]
    let audience: String
}

private final class OAuthStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw MCPAuthorizationError.storage(message)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=3000")
        try execute("""
            CREATE TABLE IF NOT EXISTS oauth_clients (
                client_id TEXT PRIMARY KEY,
                client_name TEXT NOT NULL,
                redirect_uris_json TEXT NOT NULL,
                scopes_json TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL,
                revoked_at REAL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS oauth_access_tokens (
                token_digest TEXT PRIMARY KEY,
                client_id TEXT NOT NULL REFERENCES oauth_clients(client_id),
                scopes_json TEXT NOT NULL,
                audience TEXT NOT NULL,
                expires_at REAL NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS oauth_refresh_tokens (
                token_digest TEXT PRIMARY KEY,
                client_id TEXT NOT NULL REFERENCES oauth_clients(client_id),
                scopes_json TEXT NOT NULL,
                audience TEXT NOT NULL,
                expires_at REAL NOT NULL,
                created_at REAL NOT NULL,
                consumed_at REAL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS oauth_access_expiry ON oauth_access_tokens(expires_at)")
        try execute("CREATE INDEX IF NOT EXISTS oauth_refresh_expiry ON oauth_refresh_tokens(expires_at)")
    }

    deinit { sqlite3_close(database) }

    func insert(client: OAuthClientRegistration, at date: Date) throws {
        try lock.withLock {
            let sql = "INSERT INTO oauth_clients(client_id, client_name, redirect_uris_json, created_at) VALUES(?, ?, ?, ?)"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(client.clientID, 1, statement)
            bind(client.clientName, 2, statement)
            bind(json(client.redirectURIs), 3, statement)
            sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
            try step(statement)
        }
    }

    func client(id: String) throws -> StoredOAuthClient? {
        try lock.withLock {
            let statement = try prepare("SELECT client_id, client_name, redirect_uris_json FROM oauth_clients WHERE client_id = ? AND revoked_at IS NULL LIMIT 1")
            defer { sqlite3_finalize(statement) }
            bind(id, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredOAuthClient(
                clientID: text(statement, 0),
                clientName: text(statement, 1),
                redirectURIs: strings(text(statement, 2))
            )
        }
    }

    func recordGrant(clientID: String, scopes: [String], at date: Date) throws {
        try lock.withLock {
            let statement = try prepare("UPDATE oauth_clients SET scopes_json = ?, last_used_at = ? WHERE client_id = ? AND revoked_at IS NULL")
            defer { sqlite3_finalize(statement) }
            bind(json(scopes), 1, statement)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            bind(clientID, 3, statement)
            try step(statement)
        }
    }

    func insertAccessToken(digest: String, clientID: String, scopes: [String], audience: String, expiresAt: Date, at date: Date) throws {
        try lock.withLock {
            let statement = try prepare("INSERT INTO oauth_access_tokens(token_digest, client_id, scopes_json, audience, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(digest, 1, statement)
            bind(clientID, 2, statement)
            bind(json(scopes), 3, statement)
            bind(audience, 4, statement)
            sqlite3_bind_double(statement, 5, expiresAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
            try step(statement)
        }
    }

    func insertRefreshToken(digest: String, clientID: String, scopes: [String], audience: String, expiresAt: Date, at date: Date) throws {
        try lock.withLock {
            let statement = try prepare("INSERT INTO oauth_refresh_tokens(token_digest, client_id, scopes_json, audience, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(digest, 1, statement)
            bind(clientID, 2, statement)
            bind(json(scopes), 3, statement)
            bind(audience, 4, statement)
            sqlite3_bind_double(statement, 5, expiresAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
            try step(statement)
        }
    }

    func accessToken(digest: String, now: Date) throws -> StoredAccessToken? {
        try lock.withLock {
            let statement = try prepare("""
                SELECT t.client_id, c.client_name, t.scopes_json, t.audience
                FROM oauth_access_tokens t JOIN oauth_clients c ON c.client_id = t.client_id
                WHERE t.token_digest = ? AND t.expires_at > ? AND c.revoked_at IS NULL LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            bind(digest, 1, statement)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredAccessToken(
                clientID: text(statement, 0),
                clientName: text(statement, 1),
                scopes: strings(text(statement, 2)),
                audience: text(statement, 3)
            )
        }
    }

    func consumeRefreshToken(digest: String, clientID: String, now: Date) throws -> StoredRefreshToken? {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare("""
                    SELECT scopes_json, audience FROM oauth_refresh_tokens
                    WHERE token_digest = ? AND client_id = ? AND expires_at > ? AND consumed_at IS NULL LIMIT 1
                    """)
                bind(digest, 1, statement)
                bind(clientID, 2, statement)
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    sqlite3_finalize(statement)
                    try execute("ROLLBACK")
                    return nil
                }
                let record = StoredRefreshToken(scopes: strings(text(statement, 0)), audience: text(statement, 1))
                sqlite3_finalize(statement)

                let update = try prepare("UPDATE oauth_refresh_tokens SET consumed_at = ? WHERE token_digest = ? AND consumed_at IS NULL")
                sqlite3_bind_double(update, 1, now.timeIntervalSince1970)
                bind(digest, 2, update)
                try step(update)
                sqlite3_finalize(update)
                try execute("COMMIT")
                return record
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func touchClient(id: String, at date: Date) throws {
        try lock.withLock {
            let statement = try prepare("UPDATE oauth_clients SET last_used_at = ? WHERE client_id = ? AND revoked_at IS NULL")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(id, 2, statement)
            try step(statement)
        }
    }

    func authorizedClients() throws -> [AuthorizedMCPClient] {
        try lock.withLock {
            let statement = try prepare("""
                SELECT client_id, client_name, scopes_json, created_at, last_used_at
                FROM oauth_clients WHERE revoked_at IS NULL AND scopes_json IS NOT NULL
                ORDER BY COALESCE(last_used_at, created_at) DESC
                """)
            defer { sqlite3_finalize(statement) }
            var clients: [AuthorizedMCPClient] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                clients.append(AuthorizedMCPClient(
                    id: text(statement, 0),
                    name: text(statement, 1),
                    scopes: strings(text(statement, 2)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    lastUsedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
            }
            return clients
        }
    }

    func revokeClient(id: String, at date: Date) throws {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare("UPDATE oauth_clients SET revoked_at = ? WHERE client_id = ?")
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                bind(id, 2, statement)
                try step(statement)
                sqlite3_finalize(statement)
                let access = try prepare("DELETE FROM oauth_access_tokens WHERE client_id = ?")
                bind(id, 1, access)
                try step(access)
                sqlite3_finalize(access)
                let refresh = try prepare("DELETE FROM oauth_refresh_tokens WHERE client_id = ?")
                bind(id, 1, refresh)
                try step(refresh)
                sqlite3_finalize(refresh)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func removeExpiredTokens(now: Date) throws {
        try lock.withLock {
            let access = try prepare("DELETE FROM oauth_access_tokens WHERE expires_at <= ?")
            sqlite3_bind_double(access, 1, now.timeIntervalSince1970)
            try step(access)
            sqlite3_finalize(access)
            let refresh = try prepare("DELETE FROM oauth_refresh_tokens WHERE expires_at <= ? OR consumed_at IS NOT NULL")
            sqlite3_bind_double(refresh, 1, now.timeIntervalSince1970)
            try step(refresh)
            sqlite3_finalize(refresh)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MCPAuthorizationError.storage(errorMessage)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MCPAuthorizationError.storage(errorMessage)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MCPAuthorizationError.storage(errorMessage)
        }
    }

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func json(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func strings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return values
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    }
}

private enum LocalSecretStore {
    private static var localSecretURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Payvand", isDirectory: true)
            .appendingPathComponent("oauth-pepper-v1")
    }

    static func loadOrCreateTokenPepper() throws -> Data {
        if let local = try? Data(contentsOf: localSecretURL), local.count >= 32 {
            return local
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw MCPAuthorizationError.keychain(randomStatus) }
        let data = Data(bytes)
        // The MCP service is loopback-only and the database stores keyed token
        // digests, not bearer tokens. A per-user 0600 secret avoids Keychain
        // prompts and identity churn in ad-hoc development builds.
        try persistLocally(data)
        return data
    }

    private static func persistLocally(_ data: Data) throws {
        let directory = localSecretURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: localSecretURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: localSecretURL.path
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
