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
            try JSONSerialization.data(withJSONObject: request)
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
        let server = LocalHTTPServer(port: 0, handler: MCPProtocolHandler(database: database))
        try server.start()
        defer { server.stop() }

        let completed = expectation(description: "MCP HTTP response")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": [:]
        ])
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertNotNil(object?["result"])
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 3)
    }

    private func temporaryDatabase() throws -> (MemoryDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBarTests-\(UUID().uuidString)", isDirectory: true)
        let database = try MemoryDatabase(url: directory.appendingPathComponent("memory.sqlite3"))
        return (database, directory)
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
