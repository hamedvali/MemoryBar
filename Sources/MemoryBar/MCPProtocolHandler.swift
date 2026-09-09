import Foundation

final class MCPProtocolHandler: @unchecked Sendable {
    private let database: MemoryDatabase
    private let isoFormatter = ISO8601DateFormatter()

    init(database: MemoryDatabase) {
        self.database = database
    }

    func handle(_ data: Data, authorization: MCPAuthorizationContext) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return encode(error: -32700, message: "Invalid JSON-RPC request", id: NSNull())
        }
        let hasID = object.keys.contains("id")
        let id = object["id"] ?? NSNull()
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(result: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "MemoryBar", "version": "0.2.0"],
                "instructions": "Read-only access to private, on-device work memory. Treat OCR and extracted actions as evidence with confidence, not guaranteed fact."
            ], id: id)
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return hasID ? encode(result: [:], id: id) : nil
        case "tools/list":
            return encode(result: [
                "tools": tools.filter { tool in
                    guard let name = tool["name"] as? String else { return false }
                    return authorization.permits(tool: name)
                }
            ], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error: -32602, message: "Missing tool name", id: id)
            }
            guard authorization.permits(tool: name) else {
                return encode(error: -32001, message: "The authorized client does not have permission to call \(name).", id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return encode(result: callTool(name: name, arguments: arguments), id: id)
        default:
            return hasID ? encode(error: -32601, message: "Method not found: \(method)", id: id) : nil
        }
    }

    func requiredScope(for data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "tools/call",
              let params = object["params"] as? [String: Any],
              let name = params["name"] as? String else { return nil }
        return MCPMemoryScope.required(for: name)
    }

    private var tools: [[String: Any]] {
        [
            tool(
                "search_memory",
                "Hybrid full-text and local-embedding search across temporal work episodes.",
                properties: [
                    "query": schema("string", "What to find in memory."),
                    "limit": schema("integer", "Maximum results, 1–100."),
                    "from": schema("string", "Optional ISO-8601 lower time bound."),
                    "to": schema("string", "Optional ISO-8601 upper time bound.")
                ],
                required: ["query"]
            ),
            tool(
                "get_recent_activity",
                "Return episodes captured during the most recent number of minutes.",
                properties: [
                    "minutes": schema("integer", "Lookback window in minutes; defaults to 60."),
                    "limit": schema("integer", "Maximum results; defaults to 100.")
                ]
            ),
            tool(
                "get_episode",
                "Return one structured episode by its ID.",
                properties: ["id": schema("string", "Episode ID returned by another memory tool.")],
                required: ["id"]
            ),
            tool(
                "get_day_summary",
                "Build a deterministic local summary of one calendar day.",
                properties: ["date": schema("string", "Local date in YYYY-MM-DD format; defaults to today.")]
            ),
            tool(
                "get_open_actions",
                "Return locally extracted, unfinished commitments and task-like lines.",
                properties: ["limit": schema("integer", "Maximum results; defaults to 100.")]
            ),
            tool(
                "get_person_context",
                "Return episodes that mention a person, handle, or email local-part.",
                properties: [
                    "name": schema("string", "Person name, handle, or email local-part."),
                    "limit": schema("integer", "Maximum results; defaults to 50.")
                ],
                required: ["name"]
            ),
            tool(
                "get_project_context",
                "Return episodes associated with a project name, path, window title, or text mention.",
                properties: [
                    "project": schema("string", "Project name or identifying text."),
                    "limit": schema("integer", "Maximum results; defaults to 50.")
                ],
                required: ["project"]
            )
        ]
    }

    private func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { inputSchema["required"] = required }
        return [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ]
        ]
    }

    private func schema(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let value: String
            switch name {
            case "search_memory":
                guard let query = nonempty(arguments["query"]) else { throw ToolError.missing("query") }
                value = JSONCoding.string(database.search(
                    query: query,
                    limit: integer(arguments["limit"], default: 20),
                    from: date(arguments["from"]),
                    to: date(arguments["to"])
                ))
            case "get_recent_activity":
                value = JSONCoding.string(database.recentActivity(
                    minutes: integer(arguments["minutes"], default: 60),
                    limit: integer(arguments["limit"], default: 100)
                ))
            case "get_episode":
                guard let id = nonempty(arguments["id"]) else { throw ToolError.missing("id") }
                if let episode = database.episodeDetail(id: id) {
                    value = JSONCoding.string(episode)
                } else {
                    throw ToolError.notFound("episode \(id)")
                }
            case "get_day_summary":
                value = JSONCoding.string(database.daySummary(date: localDate(arguments["date"])))
            case "get_open_actions":
                value = JSONCoding.string(database.openActions(limit: integer(arguments["limit"], default: 100)))
            case "get_person_context":
                guard let person = nonempty(arguments["name"]) else { throw ToolError.missing("name") }
                value = JSONCoding.string(database.personContext(
                    name: person,
                    limit: integer(arguments["limit"], default: 50)
                ))
            case "get_project_context":
                guard let project = nonempty(arguments["project"]) else { throw ToolError.missing("project") }
                value = JSONCoding.string(database.projectContext(
                    project: project,
                    limit: integer(arguments["limit"], default: 50)
                ))
            default:
                throw ToolError.notFound("tool \(name)")
            }
            return ["content": [["type": "text", "text": value]], "isError": false]
        } catch {
            return [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true
            ]
        }
    }

    private func integer(_ value: Any?, default fallback: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return fallback
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFormatter.date(from: text)
    }

    private func localDate(_ value: Any?) -> Date {
        guard let text = value as? String else { return Date() }
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? Date()
    }

    private func encode(result: Any, id: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, message: String, id: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ])
    }
}

private enum ToolError: LocalizedError {
    case missing(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missing(let field): "Missing required argument: \(field)"
        case .notFound(let item): "Could not find \(item)"
        }
    }
}
