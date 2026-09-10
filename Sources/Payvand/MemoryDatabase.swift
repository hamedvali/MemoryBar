import Foundation
import SQLite3

enum MemoryDatabaseError: LocalizedError {
    case open(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the local memory database: \(message)"
        case .sqlite(let message): "SQLite error: \(message)"
        }
    }
}

final class MemoryDatabase: @unchecked Sendable {
    let url: URL

    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let embedding = EmbeddingEngine.shared
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw MemoryDatabaseError.open(message)
        }
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    func ingest(_ observation: ObservationDraft) throws -> EpisodeRecord {
        try synchronized {
            try execute("BEGIN IMMEDIATE")
            do {
                try insertObservation(observation)
                let previous = try mostRecentEpisode()
                let key = TextIntelligence.episodeKey(observation.context)
                let canMerge = previous.map {
                    TextIntelligence.episodeKey(WindowContext(
                        appName: $0.appName,
                        bundleIdentifier: $0.bundleIdentifier,
                        windowTitle: $0.windowTitle
                    )) == key && observation.capturedAt.timeIntervalSince($0.endAt) <= 120
                } ?? false

                let episode: EpisodeRecord
                if let previous, canMerge {
                    episode = try merge(observation, into: previous)
                } else {
                    episode = try createEpisode(from: observation)
                }
                try execute("COMMIT")
                return episode
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func counts() -> (observations: Int, episodes: Int) {
        synchronized {
            (scalarInt("SELECT COUNT(*) FROM observations"), scalarInt("SELECT COUNT(*) FROM episodes"))
        }
    }

    func deleteAllMemory() throws {
        try synchronized {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM actions")
                try execute("DELETE FROM observations")
                try execute("DELETE FROM episodes")
                try execute("DELETE FROM episodes_fts")
                try execute("COMMIT")
                try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func episode(id: String) -> EpisodeRecord? {
        synchronized {
            let sql = "SELECT \(episodeColumns) FROM episodes WHERE id = ? LIMIT 1"
            guard let statement = try? prepare(sql) else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeEpisode(statement)
        }
    }

    func episodeDetail(id: String) -> EpisodeDetail? {
        synchronized {
            guard let episode = episode(id: id) else { return nil }
            let sql = """
                SELECT id, captured_at, app_name, bundle_id, window_title, document_url,
                       exact_text, confidence, change_score, evidence_json,
                       CASE WHEN thumbnail_jpeg IS NULL THEN 0 ELSE 1 END
                FROM observations
                WHERE captured_at >= ? AND captured_at <= ? AND bundle_id = ? AND window_title = ?
                ORDER BY captured_at ASC
                """
            guard let statement = try? prepare(sql) else { return EpisodeDetail(episode: episode, evidence: []) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, episode.startAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, episode.endAt.timeIntervalSince1970)
            bind(episode.bundleIdentifier, at: 3, in: statement)
            bind(episode.windowTitle, at: 4, in: statement)
            var evidence: [ObservationEvidence] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                evidence.append(ObservationEvidence(
                    id: textColumn(statement, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    appName: textColumn(statement, 2),
                    bundleIdentifier: textColumn(statement, 3),
                    windowTitle: textColumn(statement, 4),
                    documentURL: optionalTextColumn(statement, 5),
                    exactText: textColumn(statement, 6),
                    confidence: sqlite3_column_double(statement, 7),
                    changeScore: sqlite3_column_double(statement, 8),
                    evidenceJSON: textColumn(statement, 9),
                    hasThumbnail: sqlite3_column_int(statement, 10) == 1
                ))
            }
            return EpisodeDetail(episode: episode, evidence: evidence)
        }
    }

    func recentActivity(minutes: Int, limit: Int = 100) -> [EpisodeRecord] {
        synchronized {
            let cutoff = Date().addingTimeInterval(-Double(max(1, minutes)) * 60)
            return queryEpisodes(
                whereClause: "end_at >= ?",
                bindings: [.double(cutoff.timeIntervalSince1970)],
                order: "end_at DESC",
                limit: min(max(limit, 1), 500)
            )
        }
    }

    func search(query: String, limit: Int = 20, from: Date? = nil, to: Date? = nil) -> [MemorySearchResult] {
        synchronized {
            let safeLimit = min(max(limit, 1), 100)
            let queryVector = embedding.vector(for: query)
            var lexicalScores: [String: Double] = [:]
            let matchQuery = ftsQuery(query)

            if !matchQuery.isEmpty,
               let statement = try? prepare(
                """
                SELECT episode_id, bm25(episodes_fts)
                FROM episodes_fts
                WHERE episodes_fts MATCH ?
                ORDER BY bm25(episodes_fts)
                LIMIT 100
                """
               ) {
                bind(matchQuery, at: 1, in: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = textColumn(statement, 0)
                    let rank = abs(sqlite3_column_double(statement, 1))
                    lexicalScores[id] = 1 / (1 + rank)
                }
                sqlite3_finalize(statement)
            }

            var clauses: [String] = []
            var bindings: [SQLiteValue] = []
            if let from {
                clauses.append("end_at >= ?")
                bindings.append(.double(from.timeIntervalSince1970))
            }
            if let to {
                clauses.append("start_at <= ?")
                bindings.append(.double(to.timeIntervalSince1970))
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            let sql = "SELECT \(episodeColumns), embedding FROM episodes \(whereSQL) ORDER BY end_at DESC LIMIT 500"
            guard let statement = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            apply(bindings, to: statement)

            var results: [MemorySearchResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let episode = decodeEpisode(statement)
                let data = blobColumn(statement, 13)
                let semantic = embedding.cosine(queryVector, embedding.vector(from: data))
                let lexical = lexicalScores[episode.id] ?? 0
                let recencyDays = max(0, Date().timeIntervalSince(episode.endAt) / 86_400)
                let recency = 1 / (1 + recencyDays / 30)
                let score = semantic * 0.60 + lexical * 0.32 + recency * 0.08
                if semantic > 0.05 || lexical > 0 {
                    results.append(MemorySearchResult(episode: episode, score: score))
                }
            }
            return results.sorted { $0.score > $1.score }.prefix(safeLimit).map { $0 }
        }
    }

    func openActions(limit: Int = 100) -> [ActionRecord] {
        synchronized {
            let sql = "SELECT id, episode_id, text, detected_at, status FROM actions WHERE status = 'open' ORDER BY detected_at DESC LIMIT ?"
            guard let statement = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(min(max(limit, 1), 500)))
            var results: [ActionRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(ActionRecord(
                    id: textColumn(statement, 0),
                    episodeID: textColumn(statement, 1),
                    text: textColumn(statement, 2),
                    detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    status: textColumn(statement, 4)
                ))
            }
            return results
        }
    }

    func personContext(name: String, limit: Int = 50) -> [EpisodeRecord] {
        synchronized {
            queryEpisodes(
                whereClause: "lower(people_json) LIKE ? OR lower(exact_text) LIKE ?",
                bindings: [.text("%\(name.lowercased())%"), .text("%\(name.lowercased())%")],
                order: "end_at DESC",
                limit: min(max(limit, 1), 200)
            )
        }
    }

    func projectContext(project: String, limit: Int = 50) -> [EpisodeRecord] {
        synchronized {
            queryEpisodes(
                whereClause: "lower(project) LIKE ? OR lower(window_title) LIKE ? OR lower(exact_text) LIKE ?",
                bindings: Array(repeating: .text("%\(project.lowercased())%"), count: 3),
                order: "end_at DESC",
                limit: min(max(limit, 1), 200)
            )
        }
    }

    func daySummary(date: Date, calendar: Calendar = .current) -> DaySummary {
        synchronized {
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let episodes = queryEpisodes(
                whereClause: "end_at >= ? AND start_at < ?",
                bindings: [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)],
                order: "start_at ASC",
                limit: 1_000
            )

            var apps: [String: Int] = [:]
            var activeSeconds: TimeInterval = 0
            for episode in episodes {
                let seconds = max(10, episode.endAt.timeIntervalSince(episode.startAt))
                activeSeconds += seconds
                apps[episode.appName, default: 0] += max(1, Int((seconds / 60).rounded()))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return DaySummary(
                date: formatter.string(from: start),
                episodeCount: episodes.count,
                activeMinutes: Int((activeSeconds / 60).rounded()),
                topApplications: apps,
                highlights: episodes.suffix(12).map(\.summary),
                openActions: openActions(limit: 50).filter { $0.detectedAt >= start && $0.detectedAt < end }
            )
        }
    }

    private func migrate() throws {
        try synchronized {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=3000")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS observations (
                    id TEXT PRIMARY KEY,
                    captured_at REAL NOT NULL,
                    app_name TEXT NOT NULL,
                    bundle_id TEXT NOT NULL,
                    window_title TEXT NOT NULL,
                    document_url TEXT,
                    exact_text TEXT NOT NULL,
                    vision_labels_json TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    change_score REAL NOT NULL,
                    evidence_json TEXT NOT NULL,
                    thumbnail_jpeg BLOB
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS episodes (
                    id TEXT PRIMARY KEY,
                    start_at REAL NOT NULL,
                    end_at REAL NOT NULL,
                    app_name TEXT NOT NULL,
                    bundle_id TEXT NOT NULL,
                    window_title TEXT NOT NULL,
                    project TEXT,
                    summary TEXT NOT NULL,
                    exact_text TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    people_json TEXT NOT NULL,
                    actions_json TEXT NOT NULL,
                    observation_count INTEGER NOT NULL,
                    embedding BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS actions (
                    id TEXT PRIMARY KEY,
                    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
                    text TEXT NOT NULL,
                    normalized_text TEXT NOT NULL,
                    detected_at REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'open',
                    UNIQUE(episode_id, normalized_text)
                )
                """
            )
            try execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(
                    episode_id UNINDEXED,
                    exact_text,
                    summary,
                    people,
                    project,
                    window_title,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """
            )
            try execute("CREATE INDEX IF NOT EXISTS idx_episodes_end_at ON episodes(end_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_observations_captured_at ON observations(captured_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_actions_status ON actions(status, detected_at DESC)")
        }
    }

    private func insertObservation(_ item: ObservationDraft) throws {
        let statement = try prepare(
            """
            INSERT INTO observations (
                id, captured_at, app_name, bundle_id, window_title, document_url,
                exact_text, vision_labels_json, confidence, change_score, evidence_json, thumbnail_jpeg
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(item.id, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, item.capturedAt.timeIntervalSince1970)
        bind(item.context.appName, at: 3, in: statement)
        bind(item.context.bundleIdentifier, at: 4, in: statement)
        bind(item.context.windowTitle, at: 5, in: statement)
        bind(item.context.documentURL, at: 6, in: statement)
        bind(item.exactText, at: 7, in: statement)
        bind(JSONCoding.string(item.visionLabels), at: 8, in: statement)
        sqlite3_bind_double(statement, 9, item.confidence)
        sqlite3_bind_double(statement, 10, item.changeScore)
        bind(item.evidenceJSON, at: 11, in: statement)
        bind(item.thumbnailJPEG, at: 12, in: statement)
        try stepDone(statement)
    }

    private func createEpisode(from item: ObservationDraft) throws -> EpisodeRecord {
        let people = TextIntelligence.people(in: item.exactText)
        let actions = TextIntelligence.actions(in: item.exactText)
        let episode = EpisodeRecord(
            id: UUID().uuidString,
            startAt: item.capturedAt,
            endAt: item.capturedAt,
            appName: item.context.appName,
            bundleIdentifier: item.context.bundleIdentifier,
            windowTitle: item.context.windowTitle,
            project: TextIntelligence.project(from: item.context),
            summary: TextIntelligence.summary(app: item.context.appName, title: item.context.windowTitle, text: item.exactText),
            exactText: item.exactText,
            confidence: item.confidence,
            people: people,
            actions: actions,
            observationCount: 1
        )

        let statement = try prepare(
            """
            INSERT INTO episodes (
                id, start_at, end_at, app_name, bundle_id, window_title, project, summary,
                exact_text, confidence, people_json, actions_json, observation_count, embedding
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bindEpisode(episode, statement: statement)
        try stepDone(statement)
        try reindex(episode)
        try insertActions(actions, episodeID: episode.id, detectedAt: item.capturedAt)
        return episode
    }

    private func merge(_ item: ObservationDraft, into previous: EpisodeRecord) throws -> EpisodeRecord {
        let combinedText = TextIntelligence.normalizedText(parts: [previous.exactText, item.exactText])
        let boundedText = String(combinedText.suffix(60_000))
        let people = Array(Set(previous.people + TextIntelligence.people(in: item.exactText))).sorted()
        let actions = Array(Set(previous.actions + TextIntelligence.actions(in: item.exactText))).sorted()
        let count = previous.observationCount + 1
        let weightedConfidence = ((previous.confidence * Double(previous.observationCount)) + item.confidence) / Double(count)
        let episode = EpisodeRecord(
            id: previous.id,
            startAt: previous.startAt,
            endAt: item.capturedAt,
            appName: item.context.appName,
            bundleIdentifier: item.context.bundleIdentifier,
            windowTitle: item.context.windowTitle,
            project: TextIntelligence.project(from: item.context) ?? previous.project,
            summary: TextIntelligence.summary(app: item.context.appName, title: item.context.windowTitle, text: item.exactText),
            exactText: boundedText,
            confidence: weightedConfidence,
            people: people,
            actions: actions,
            observationCount: count
        )

        let statement = try prepare(
            """
            UPDATE episodes SET
                end_at = ?, app_name = ?, bundle_id = ?, window_title = ?, project = ?, summary = ?,
                exact_text = ?, confidence = ?, people_json = ?, actions_json = ?, observation_count = ?, embedding = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, episode.endAt.timeIntervalSince1970)
        bind(episode.appName, at: 2, in: statement)
        bind(episode.bundleIdentifier, at: 3, in: statement)
        bind(episode.windowTitle, at: 4, in: statement)
        bind(episode.project, at: 5, in: statement)
        bind(episode.summary, at: 6, in: statement)
        bind(episode.exactText, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, episode.confidence)
        bind(JSONCoding.string(episode.people), at: 9, in: statement)
        bind(JSONCoding.string(episode.actions), at: 10, in: statement)
        sqlite3_bind_int(statement, 11, Int32(episode.observationCount))
        bind(embedding.data(for: episode.exactText), at: 12, in: statement)
        bind(episode.id, at: 13, in: statement)
        try stepDone(statement)
        try reindex(episode)
        try insertActions(TextIntelligence.actions(in: item.exactText), episodeID: episode.id, detectedAt: item.capturedAt)
        return episode
    }

    private func mostRecentEpisode() throws -> EpisodeRecord? {
        let statement = try prepare("SELECT \(episodeColumns) FROM episodes ORDER BY end_at DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeEpisode(statement)
    }

    private func reindex(_ episode: EpisodeRecord) throws {
        let deleteStatement = try prepare("DELETE FROM episodes_fts WHERE episode_id = ?")
        bind(episode.id, at: 1, in: deleteStatement)
        try stepDone(deleteStatement)
        sqlite3_finalize(deleteStatement)

        let insert = try prepare(
            "INSERT INTO episodes_fts (episode_id, exact_text, summary, people, project, window_title) VALUES (?, ?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(insert) }
        bind(episode.id, at: 1, in: insert)
        bind(episode.exactText, at: 2, in: insert)
        bind(episode.summary, at: 3, in: insert)
        bind(episode.people.joined(separator: " "), at: 4, in: insert)
        bind(episode.project, at: 5, in: insert)
        bind(episode.windowTitle, at: 6, in: insert)
        try stepDone(insert)
    }

    private func insertActions(_ actions: [String], episodeID: String, detectedAt: Date) throws {
        for action in actions {
            let statement = try prepare(
                "INSERT OR IGNORE INTO actions (id, episode_id, text, normalized_text, detected_at, status) VALUES (?, ?, ?, ?, ?, 'open')"
            )
            bind(UUID().uuidString, at: 1, in: statement)
            bind(episodeID, at: 2, in: statement)
            bind(action, at: 3, in: statement)
            bind(action.lowercased(), at: 4, in: statement)
            sqlite3_bind_double(statement, 5, detectedAt.timeIntervalSince1970)
            try stepDone(statement)
            sqlite3_finalize(statement)
        }
    }

    private var episodeColumns: String {
        "id, start_at, end_at, app_name, bundle_id, window_title, project, summary, exact_text, confidence, people_json, actions_json, observation_count"
    }

    private func decodeEpisode(_ statement: OpaquePointer?) -> EpisodeRecord {
        EpisodeRecord(
            id: textColumn(statement, 0),
            startAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            endAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            appName: textColumn(statement, 3),
            bundleIdentifier: textColumn(statement, 4),
            windowTitle: textColumn(statement, 5),
            project: optionalTextColumn(statement, 6),
            summary: textColumn(statement, 7),
            exactText: textColumn(statement, 8),
            confidence: sqlite3_column_double(statement, 9),
            people: decodeStrings(textColumn(statement, 10)),
            actions: decodeStrings(textColumn(statement, 11)),
            observationCount: Int(sqlite3_column_int(statement, 12))
        )
    }

    private func bindEpisode(_ episode: EpisodeRecord, statement: OpaquePointer?) {
        bind(episode.id, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, episode.startAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, episode.endAt.timeIntervalSince1970)
        bind(episode.appName, at: 4, in: statement)
        bind(episode.bundleIdentifier, at: 5, in: statement)
        bind(episode.windowTitle, at: 6, in: statement)
        bind(episode.project, at: 7, in: statement)
        bind(episode.summary, at: 8, in: statement)
        bind(episode.exactText, at: 9, in: statement)
        sqlite3_bind_double(statement, 10, episode.confidence)
        bind(JSONCoding.string(episode.people), at: 11, in: statement)
        bind(JSONCoding.string(episode.actions), at: 12, in: statement)
        sqlite3_bind_int(statement, 13, Int32(episode.observationCount))
        bind(embedding.data(for: episode.exactText), at: 14, in: statement)
    }

    private func queryEpisodes(whereClause: String, bindings: [SQLiteValue], order: String, limit: Int) -> [EpisodeRecord] {
        let sql = "SELECT \(episodeColumns) FROM episodes WHERE \(whereClause) ORDER BY \(order) LIMIT \(limit)"
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        apply(bindings, to: statement)
        var results: [EpisodeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(decodeEpisode(statement))
        }
        return results
    }

    private func ftsQuery(_ text: String) -> String {
        text.split { !$0.isLetter && !$0.isNumber }
            .prefix(12)
            .map { "\"\(String($0).replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private func decodeStrings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return result
    }

    private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryDatabaseError.sqlite(errorMessage)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw MemoryDatabaseError.sqlite(message)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MemoryDatabaseError.sqlite(errorMessage)
        }
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func scalarInt(_ sql: String) -> Int {
        guard let statement = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Data?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func optionalTextColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return textColumn(statement, index)
    }

    private func blobColumn(_ statement: OpaquePointer?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private enum SQLiteValue {
        case text(String)
        case double(Double)
    }

    private func apply(_ bindings: [SQLiteValue], to statement: OpaquePointer?) {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): bind(text, at: index, in: statement)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            }
        }
    }
}
