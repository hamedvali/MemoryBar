import Foundation
import XCTest
@testable import MemoryBar

final class MemoryBarTests: XCTestCase {
    func testActionAndPersonExtraction() {
        let text = """
        Met with Sarah Connor about launch.
        TODO: review PR #123
        I'll send the notes tomorrow.
        @julius will check the build.
        """
        XCTAssertTrue(TextIntelligence.people(in: text).contains("Sarah Connor"))
        XCTAssertTrue(TextIntelligence.people(in: text).contains("julius"))
        XCTAssertEqual(TextIntelligence.actions(in: text).count, 2)
    }

    func testEpisodeMergeSearchAndActions() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let context = WindowContext(
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "MemoryBar — CaptureService.swift",
            documentURL: "file:///Documents/MemoryBar/Sources/CaptureService.swift"
        )
        _ = try database.ingest(observation(
            at: now,
            context: context,
            text: "Implement smart screenshot change detection. TODO: verify OCR tests"
        ))
        let merged = try database.ingest(observation(
            at: now.addingTimeInterval(20),
            context: context,
            text: "Vision OCR and local image classification are running."
        ))

        XCTAssertEqual(database.counts().observations, 2)
        XCTAssertEqual(database.counts().episodes, 1)
        XCTAssertEqual(merged.observationCount, 2)
        XCTAssertFalse(database.search(query: "screenshot OCR").isEmpty)
        XCTAssertTrue(database.openActions().first?.text.contains("verify OCR tests") == true)
        XCTAssertFalse(database.projectContext(project: "MemoryBar").isEmpty)
    }

    func testDifferentWindowCreatesNewEpisode() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        _ = try database.ingest(observation(
            at: now,
            context: WindowContext(appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Docs"),
            text: "MCP documentation"
        ))
        _ = try database.ingest(observation(
            at: now.addingTimeInterval(5),
            context: WindowContext(appName: "Mail", bundleIdentifier: "com.apple.mail", windowTitle: "Inbox"),
            text: "Message from Alex"
        ))
        XCTAssertEqual(database.counts().episodes, 2)
    }

    func testMCPListsSevenReadOnlyTools() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ]
        let response = MCPProtocolHandler(database: database).handle(
            try JSONSerialization.data(withJSONObject: request),
            authorization: .testFullAccess
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 7)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set([
            "search_memory", "get_recent_activity", "get_episode", "get_day_summary",
            "get_open_actions", "get_person_context", "get_project_context"
        ]))
    }

    func testLoopbackHTTPTransport() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorization = try testAuthorization(in: directory)
        let server = LocalHTTPServer(
            port: 0,
            handler: MCPProtocolHandler(database: database),
            authorization: authorization
        )
        try server.start()
        defer { server.stop() }

        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": [:]
        ])
        let unauthorized = expectation(description: "Unauthenticated MCP response")
        var unauthenticatedRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
        unauthenticatedRequest.httpMethod = "POST"
        unauthenticatedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthenticatedRequest.httpBody = body
        URLSession.shared.dataTask(with: unauthenticatedRequest) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            XCTAssertNotNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate"))
            unauthorized.fulfill()
        }.resume()
        wait(for: [unauthorized], timeout: 3)

        let browserClient = try authorization.registerClient(
            name: "Browser Test Client",
            redirectURIs: ["http://127.0.0.1:49153/callback"]
        )
        var authorizationURL = URLComponents(string: "http://127.0.0.1:\(server.port)/authorize")!
        authorizationURL.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: browserClient.clientID),
            URLQueryItem(name: "redirect_uri", value: browserClient.redirectURIs[0]),
            URLQueryItem(name: "code_challenge", value: MCPAuthorizationService.pkceChallenge(for: String(repeating: "z", count: 64))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "\(MCPMemoryScope.recent) \(MCPMemoryScope.search)"),
            URLQueryItem(name: "resource", value: authorization.resourceURL),
            URLQueryItem(name: "state", value: "browser-test")
        ]
        let plusEncodedURL = try XCTUnwrap(URL(string: authorizationURL.string!.replacingOccurrences(of: "%20", with: "+")))
        let approvalPage = expectation(description: "OAuth approval page")
        URLSession.shared.dataTask(with: plusEncodedURL) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(data.map { String(decoding: $0, as: UTF8.self).contains("Browser Test Client") } == true)
            approvalPage.fulfill()
        }.resume()
        wait(for: [approvalPage], timeout: 3)

        let token = try authorize(authorization, scopes: MCPMemoryScope.all).accessToken
        let completed = expectation(description: "Authenticated MCP response")
        var authenticatedRequest = unauthenticatedRequest
        authenticatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: authenticatedRequest) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertNotNil(object?["result"])
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 3)
    }

    func testOAuthPKCEScopesRefreshRotationAndRevocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBarOAuthTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorization = try testAuthorization(in: directory)
        let token = try authorize(authorization, scopes: [MCPMemoryScope.recent])

        let context = try XCTUnwrap(authorization.authenticate(authorizationHeader: "Bearer \(token.accessToken)"))
        XCTAssertTrue(context.permits(tool: "get_recent_activity"))
        XCTAssertFalse(context.permits(tool: "search_memory"))
        XCTAssertEqual(authorization.authorizedClients().count, 1)

        let clientID = context.clientID
        let refreshed = try authorization.exchangeToken([
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": clientID,
            "resource": authorization.resourceURL
        ])
        XCTAssertNotNil(authorization.authenticate(authorizationHeader: "Bearer \(refreshed.accessToken)"))
        XCTAssertThrowsError(try authorization.exchangeToken([
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": clientID,
            "resource": authorization.resourceURL
        ]))

        try authorization.revoke(clientID: clientID)
        XCTAssertNil(authorization.authenticate(authorizationHeader: "Bearer \(refreshed.accessToken)"))
        XCTAssertTrue(authorization.authorizedClients().isEmpty)
    }

    func testOAuthOriginPolicyAllowsSafariOpaqueApprovalOnly() {
        XCTAssertTrue(LocalHTTPServer.isTrustedOrigin(
            method: "POST",
            path: "/authorize/decision",
            origin: "null"
        ))
        XCTAssertTrue(LocalHTTPServer.isTrustedOrigin(
            method: "POST",
            path: "/token",
            origin: "http://127.0.0.1:7331"
        ))
        XCTAssertFalse(LocalHTTPServer.isTrustedOrigin(
            method: "POST",
            path: "/token",
            origin: "null"
        ))
        XCTAssertFalse(LocalHTTPServer.isTrustedOrigin(
            method: "POST",
            path: "/authorize/decision",
            origin: "https://attacker.example"
        ))
    }

    func testConsentPageAllowsTheClientCallbackInFormAction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBarCSPTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try testAuthorization(in: directory)
        let redirectURI = "http://localhost:49155/callback"
        let client = try service.registerClient(name: "CSP Client", redirectURIs: [redirectURI])
        let prompt = try service.prepareAuthorization([
            "response_type": "code",
            "client_id": client.clientID,
            "redirect_uri": redirectURI,
            "code_challenge": MCPAuthorizationService.pkceChallenge(for: String(repeating: "c", count: 64)),
            "code_challenge_method": "S256",
            "resource": service.resourceURL
        ])

        // Browsers apply form-action to every hop of the submission, including
        // the 303 that hands the authorization code back to the MCP client. A
        // bare 'self' leaves the user on a consent page that never advances.
        XCTAssertEqual(prompt.redirectOrigin, "http://localhost:49155")
        XCTAssertTrue(
            prompt.contentSecurityPolicy.contains("form-action 'self' http://localhost:49155;"),
            "The consent page must allow the callback origin: \(prompt.contentSecurityPolicy)"
        )
    }

    func testRedirectOriginKeepsSchemeHostAndPort() {
        XCTAssertEqual(MCPAuthorizationService.origin(of: "http://127.0.0.1:8080/cb?x=1"), "http://127.0.0.1:8080")
        XCTAssertEqual(MCPAuthorizationService.origin(of: "http://[::1]:8080/cb"), "http://[::1]:8080")
        XCTAssertEqual(MCPAuthorizationService.origin(of: "http://localhost/cb"), "http://localhost")
        XCTAssertNil(MCPAuthorizationService.origin(of: "not a url"))
    }

    func testOAuthApprovalIsIdempotentForDuplicateClicks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBarOAuthRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try testAuthorization(in: directory)
        let verifier = String(repeating: "r", count: 64)
        let redirectURI = "http://127.0.0.1:49154/callback"
        let client = try service.registerClient(name: "Retry Client", redirectURIs: [redirectURI])
        let prompt = try service.prepareAuthorization([
            "response_type": "code",
            "client_id": client.clientID,
            "redirect_uri": redirectURI,
            "code_challenge": MCPAuthorizationService.pkceChallenge(for: verifier),
            "code_challenge_method": "S256",
            "scope": MCPMemoryScope.recent,
            "resource": service.resourceURL
        ])

        let firstDestination = try XCTUnwrap(
            service.completeAuthorization(requestID: prompt.requestID, approved: true)
        )
        XCTAssertEqual(
            try service.completeAuthorization(requestID: prompt.requestID, approved: true),
            firstDestination,
            "A lost first browser response must be safely replayable."
        )

        let code = try XCTUnwrap(URLComponents(url: firstDestination, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "code" })?.value)
        _ = try service.exchangeToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "resource": service.resourceURL
        ])
        XCTAssertNil(
            try service.completeAuthorization(requestID: prompt.requestID, approved: true),
            "After Claude redeems the code, a duplicate click must not replay it."
        )
    }

    private func temporaryDatabase() throws -> (MemoryDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBarTests-\(UUID().uuidString)", isDirectory: true)
        let database = try MemoryDatabase(url: directory.appendingPathComponent("memory.sqlite3"))
        return (database, directory)
    }

    private func testAuthorization(in directory: URL) throws -> MCPAuthorizationService {
        try MCPAuthorizationService(
            storageURL: directory.appendingPathComponent("authorization.sqlite3"),
            port: 7_331,
            pepperData: Data(repeating: 0xA7, count: 32)
        )
    }

    private func authorize(_ service: MCPAuthorizationService, scopes: [String]) throws -> OAuthTokenResponse {
        let verifier = String(repeating: "v", count: 64)
        let redirectURI = "http://127.0.0.1:49152/callback"
        let registration = try service.registerClient(name: "Test MCP Client", redirectURIs: [redirectURI])
        let prompt = try service.prepareAuthorization([
            "response_type": "code",
            "client_id": registration.clientID,
            "redirect_uri": redirectURI,
            "code_challenge": MCPAuthorizationService.pkceChallenge(for: verifier),
            "code_challenge_method": "S256",
            "scope": scopes.joined(separator: " "),
            "resource": service.resourceURL,
            "state": "test-state"
        ])
        let redirect = try XCTUnwrap(service.completeAuthorization(requestID: prompt.requestID, approved: true))
        let code = try XCTUnwrap(URLComponents(url: redirect, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value)
        return try service.exchangeToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": registration.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "resource": service.resourceURL
        ])
    }

    private func observation(at date: Date, context: WindowContext, text: String) -> ObservationDraft {
        ObservationDraft(
            capturedAt: date,
            context: context,
            exactText: text,
            visionLabels: [],
            confidence: 0.9,
            changeScore: 0.5,
            thumbnailJPEG: nil,
            evidenceJSON: "{}"
        )
    }
}
