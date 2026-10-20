import AgentCore
import Foundation
import SQLite3

/// Reads OpenCode 2.x sessions from `~/.local/share/opencode/opencode.db`, table `session_v2`.
/// A subagent is a session with a non-empty `parent_id`.
///
/// Activity: `time_idle` is stamped when a turn ends, so a session updated after its
/// last `time_idle` is mid-turn. `idle_outcome` keeps the previous turn's result.
public final class OpenCodeSource: AgentSource {
    public let tool = AgentTool.openCode

    private let databaseURL: URL

    public init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db"))
    {
        self.databaseURL = databaseURL
    }

    private static let query = """
        SELECT id, parent_id, agent, title, model, time_created, time_updated, idle_outcome, time_idle,
               cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, directory
        FROM session_v2
        WHERE time_updated >= ?
        ORDER BY time_created DESC
        """

    /// Updates within this margin of `time_idle` belong to closing the turn.
    private static let idleMarginMs: Int64 = 1000

    public func fetchAgents(updatedSince: Date, now: Date) throws -> [Agent] {
        try rows(sql: Self.query, since: updatedSince) { Self.agent(from: $0, now: now) }
    }

    /// Opens the database read-only, binds `since` (epoch ms) as the only parameter and maps every row.
    fileprivate func rows<T>(sql: String, since: Date, map: (OpaquePointer?) -> T?) throws -> [T] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw AgentSourceError.dataNotFound(databaseURL.path)
        }

        var db: OpaquePointer?
        // mode=ro keeps the WAL visible; immutable=1 would hide recent writes.
        let uri = "file:\(databaseURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw AgentSourceError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgentSourceError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))

        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw AgentSourceError.readFailed(String(cString: sqlite3_errmsg(db)))
            }
            if let value = map(statement) { result.append(value) }
        }
        return result
    }

    private static func agent(from statement: OpaquePointer?, now: Date) -> Agent? {
        guard let id = text(statement, 0) else { return nil }
        let parentID = text(statement, 1)
        let updatedAt = date(statement, 6)
        let updatedMs = sqlite3_column_int64(statement, 6)
        let idleMs: Int64? = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 8)
        let midTurn = idleMs.map { updatedMs - $0 > idleMarginMs } ?? true

        let status: AgentStatus
        if midTurn && ActivityPolicy.isRecent(updatedAt, now: now) {
            status = .running
        } else if parentID == nil {
            status = .idle
        } else {
            status = subagentStatus(outcome: text(statement, 7))
        }

        return Agent(
            id: id,
            tool: .openCode,
            parentSessionID: parentID,
            name: text(statement, 2) ?? (parentID == nil ? "main" : "subagent"),
            title: text(statement, 3),
            model: text(statement, 4).flatMap(decodeModel),
            status: status,
            startedAt: date(statement, 5),
            updatedAt: updatedAt,
            usage: usage(statement),
            cost: cost(statement),
            directory: text(statement, 15)
        )
    }

    private static func usage(_ statement: OpaquePointer?) -> TokenUsage? {
        let usage = TokenUsage(
            input: Int(sqlite3_column_int64(statement, 10)),
            output: Int(sqlite3_column_int64(statement, 11)),
            reasoning: Int(sqlite3_column_int64(statement, 12)),
            cacheRead: Int(sqlite3_column_int64(statement, 13)),
            cacheWrite: Int(sqlite3_column_int64(statement, 14))
        )
        return usage.isEmpty ? nil : usage
    }

    /// OpenCode stores 0 when it has no price for the model (e.g. subscription plans).
    private static func cost(_ statement: OpaquePointer?) -> Double? {
        let value = sqlite3_column_double(statement, 9)
        return value > 0 ? value : nil
    }

    private static func subagentStatus(outcome: String?) -> AgentStatus {
        switch outcome {
        case "succeeded": .succeeded
        case "failed": .failed
        case "interrupted": .interrupted
        default: .unknown
        }
    }

    private struct ModelJSON: Decodable {
        let id: String
        let providerID: String?
        let variant: String?
    }

    private static func decodeModel(_ json: String) -> ModelRef? {
        guard let decoded = try? JSONDecoder().decode(ModelJSON.self, from: Data(json.utf8)) else { return nil }
        return ModelRef(provider: decoded.providerID, id: decoded.id, variant: decoded.variant)
    }

    fileprivate static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }

    /// OpenCode stores epoch milliseconds.
    private static func date(_ statement: OpaquePointer?, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, index)) / 1000)
    }
}

extension OpenCodeSource: UsageSource {
    /// Each assistant message stores its own model, tokens, cost and time, so a session that
    /// switched models is split correctly.
    private static let usageQuery = """
        SELECT json_extract(data, '$.model.id'), json_extract(data, '$.model.providerID'),
               json_extract(data, '$.model.variant'),
               json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
               json_extract(data, '$.tokens.reasoning'),
               json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'),
               json_extract(data, '$.cost'), time_created
        FROM session_message
        WHERE type = 'assistant' AND time_created >= ?
        """

    public func fetchUsage(since: Date) throws -> [UsageEntry] {
        try rows(sql: Self.usageQuery, since: since) { statement in
            let usage = TokenUsage(
                input: Int(sqlite3_column_int64(statement, 3)),
                output: Int(sqlite3_column_int64(statement, 4)),
                reasoning: Int(sqlite3_column_int64(statement, 5)),
                cacheRead: Int(sqlite3_column_int64(statement, 6)),
                cacheWrite: Int(sqlite3_column_int64(statement, 7)))
            guard !usage.isEmpty else { return nil }

            let model = Self.text(statement, 0).map {
                ModelRef(provider: Self.text(statement, 1), id: $0, variant: Self.text(statement, 2))
            }
            let cost = sqlite3_column_double(statement, 8)
            return UsageEntry(
                tool: .openCode, model: model,
                date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 9)) / 1000),
                usage: usage, cost: cost > 0 ? cost : nil)
        }
    }
}
