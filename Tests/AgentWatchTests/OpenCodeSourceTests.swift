import Adapters
import AgentCore
import Foundation
import SQLite3
import Testing

/// Builds a throwaway `opencode.db` with the `session_v2` columns the adapter reads.
private final class OpenCodeFixture {
    let directory: URL
    let databaseURL: URL
    private var db: OpaquePointer?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentwatch-oc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("opencode.db")
        sqlite3_open(databaseURL.path, &db)
        exec("""
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, parent_id TEXT, agent TEXT, title TEXT, model TEXT,
                time_created INTEGER, time_updated INTEGER, time_idle INTEGER, idle_outcome TEXT,
                cost REAL DEFAULT 0, tokens_input INTEGER DEFAULT 0, tokens_output INTEGER DEFAULT 0,
                tokens_reasoning INTEGER DEFAULT 0, tokens_cache_read INTEGER DEFAULT 0,
                tokens_cache_write INTEGER DEFAULT 0, directory TEXT
            )
            """)
        exec("""
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT
            )
            """)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Times are epoch seconds; stored as milliseconds like OpenCode does.
    func insert(
        id: String, parent: String? = nil, agent: String? = "build", title: String? = "Task",
        model: String? = #"{"id":"gpt-6-luna","providerID":"openai","variant":"high"}"#,
        created: Double = 0, updated: Double, idle: Double?, outcome: String?,
        directory: String? = nil,
        cost: Double = 0, tokens: (input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int) = (0, 0, 0, 0, 0)
    ) {
        func sql(_ value: String?) -> String {
            value.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        }
        func ms(_ seconds: Double?) -> String { seconds.map { String(Int64($0 * 1000)) } ?? "NULL" }
        exec("""
            INSERT INTO session_v2 VALUES (\(sql(id)), \(sql(parent)), \(sql(agent)), \(sql(title)), \
            \(sql(model)), \(ms(created)), \(ms(updated)), \(ms(idle)), \(sql(outcome)), \
            \(cost), \(tokens.input), \(tokens.output), \(tokens.reasoning), \(tokens.cacheRead), \
            \(tokens.cacheWrite), \(sql(directory)))
            """)
    }

    private var messageCount = 0

    /// Mirrors an OpenCode 2.x message row; `data` is the JSON the tool stores.
    func insertMessage(
        type: String = "assistant", model: (id: String, provider: String, variant: String)? = ("gpt-6-luna", "openai", "high"),
        input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
        cost: Double = 0, created: Double
    ) {
        messageCount += 1
        let modelJSON = model.map { #""model":{"id":"\#($0.id)","providerID":"\#($0.provider)","variant":"\#($0.variant)"},"# } ?? ""
        let data = "{" + modelJSON + #""cost":\#(cost),"tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":\#(cacheRead),"write":\#(cacheWrite)}}}"#
        exec("INSERT INTO session_message VALUES ('m\(messageCount)', 's', '\(type)', \(messageCount), \(Int64(created * 1000)), \(Int64(created * 1000)), '\(data)')")
    }

    private func exec(_ statement: String) {
        sqlite3_exec(db, statement, nil, nil, nil)
    }
}

private let now = Date(timeIntervalSince1970: 1_000_000)
private let t = now.timeIntervalSince1970

private func fetch(_ fixture: OpenCodeFixture, since: Date = .distantPast) throws -> [String: Agent] {
    let agents = try OpenCodeSource(databaseURL: fixture.databaseURL).fetchAgents(updatedSince: since, now: now)
    return Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
}

@Suite struct OpenCodeSourceTests {
    @Test func mainSessionUpdatedAfterIdleIsRunningDespitePreviousOutcome() throws {
        // Real case: idle_outcome still says "succeeded" from the previous turn.
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", updated: t - 5, idle: t - 480, outcome: "succeeded")

        #expect(try fetch(fixture)["main"]?.status == .running)
    }

    @Test func mainSessionClosedRightAfterLastUpdateIsIdle() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", updated: t - 60, idle: t - 59.996, outcome: "succeeded")

        #expect(try fetch(fixture)["main"]?.status == .idle)
    }

    @Test func mainSessionWithStaleActivityIsIdle() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", updated: t - 600, idle: t - 7200, outcome: "succeeded")

        #expect(try fetch(fixture)["main"]?.status == .idle)
    }

    @Test(arguments: [
        ("succeeded", AgentStatus.succeeded),
        ("failed", .failed),
        ("interrupted", .interrupted),
        ("something-new", .unknown),
    ])
    func finishedSubagentMapsItsOutcome(outcome: String, expected: AgentStatus) throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "sub", parent: "main", updated: t - 60, idle: t - 59.996, outcome: outcome)

        #expect(try fetch(fixture)["sub"]?.status == expected)
    }

    @Test func subagentWithoutIdleStampIsRunningWhileRecent() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "sub", parent: "main", updated: t - 10, idle: nil, outcome: nil)

        #expect(try fetch(fixture)["sub"]?.status == .running)
    }

    @Test func abandonedSubagentWithoutIdleStampIsUnknown() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "sub", parent: "main", updated: t - 86_400, idle: nil, outcome: nil)

        #expect(try fetch(fixture)["sub"]?.status == .unknown)
    }

    @Test func mapsIdentityModelAndParent() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(
            id: "sub", parent: "main", agent: "explore", title: "Map flow",
            created: t - 100, updated: t - 50, idle: t - 49.999, outcome: "succeeded")

        let sub = try #require(try fetch(fixture)["sub"])
        #expect(sub.tool == .openCode)
        #expect(sub.parentSessionID == "main")
        #expect(sub.name == "explore")
        #expect(sub.title == "Map flow")
        #expect(sub.model == ModelRef(provider: "openai", id: "gpt-6-luna", variant: "high"))
        #expect(sub.startedAt == Date(timeIntervalSince1970: t - 100))
        #expect(sub.updatedAt == Date(timeIntervalSince1970: t - 50))
    }

    @Test func emptyAgentOnMainSessionIsNamedMain() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", agent: "", updated: t - 60, idle: t - 60, outcome: "succeeded")

        let main = try #require(try fetch(fixture)["main"])
        #expect(main.name == "main")
        #expect(main.isMainSession)
    }

    @Test func malformedModelBecomesNil() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", model: "not json", updated: t - 60, idle: t - 60, outcome: nil)

        let main = try #require(try fetch(fixture)["main"])
        #expect(main.model == nil)
    }

    @Test func excludesSessionsUpdatedBeforeWindow() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "old", updated: t - 7200, idle: t - 7200, outcome: "succeeded")
        fixture.insert(id: "new", updated: t - 60, idle: t - 60, outcome: "succeeded")

        let agents = try fetch(fixture, since: now.addingTimeInterval(-3600))
        #expect(Set(agents.keys) == ["new"])
    }

    @Test func readsTokenCountersAndCost() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(
            id: "main", updated: t - 60, idle: t - 60, outcome: "succeeded", cost: 0.42,
            tokens: (input: 697_449, output: 27_161, reasoning: 23_784, cacheRead: 10_280_704, cacheWrite: 5))

        let main = try #require(try fetch(fixture)["main"])
        #expect(main.usage == TokenUsage(
            input: 697_449, output: 27_161, reasoning: 23_784, cacheRead: 10_280_704, cacheWrite: 5))
        #expect(main.cost == 0.42)
    }

    @Test func zeroCostMeansUnknownNotFree() throws {
        // Real data: most sessions store cost 0.0 even with millions of tokens.
        let fixture = try OpenCodeFixture()
        fixture.insert(
            id: "main", updated: t - 60, idle: t - 60, outcome: "succeeded", cost: 0,
            tokens: (input: 100, output: 10, reasoning: 0, cacheRead: 0, cacheWrite: 0))

        let main = try #require(try fetch(fixture)["main"])
        #expect(main.cost == nil)
        #expect(main.usage?.input == 100)
    }

    @Test func readsTheWorkingDirectory() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(
            id: "main", updated: t - 60, idle: t - 60, outcome: "succeeded", directory: "/Users/me/code/barracuda")
        fixture.insert(id: "bare", updated: t - 60, idle: t - 60, outcome: "succeeded")

        let agents = try fetch(fixture)
        #expect(agents["main"]?.directory == "/Users/me/code/barracuda")
        #expect(agents["main"]?.projectName == "barracuda")
        #expect(agents["bare"]?.directory == nil)
        #expect(agents["bare"]?.projectName == nil)
    }

    @Test func sessionWithoutTokensHasNoUsage() throws {
        let fixture = try OpenCodeFixture()
        fixture.insert(id: "main", updated: t - 60, idle: t - 60, outcome: "succeeded")

        #expect(try fetch(fixture)["main"]?.usage == nil)
    }

    @Test func missingDatabaseThrowsDataNotFound() {
        let source = OpenCodeSource(databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db"))

        #expect {
            try source.fetchAgents(updatedSince: .distantPast, now: now)
        } throws: { error in
            if case AgentSourceError.dataNotFound = error { true } else { false }
        }
    }
}

@Suite struct OpenCodeUsageTests {
    private func usage(_ fixture: OpenCodeFixture, since: Date = .distantPast) throws -> [UsageEntry] {
        try OpenCodeSource(databaseURL: fixture.databaseURL).fetchUsage(since: since)
    }

    @Test func readsModelTokensCostAndTimePerMessage() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(
            input: 603, output: 138, reasoning: 102, cacheRead: 124_288, cacheWrite: 7, cost: 0.31, created: t - 100)

        let entry = try #require(try usage(fixture).first)
        #expect(entry.tool == .openCode)
        #expect(entry.model == ModelRef(provider: "openai", id: "gpt-6-luna", variant: "high"))
        #expect(entry.usage == TokenUsage(input: 603, output: 138, reasoning: 102, cacheRead: 124_288, cacheWrite: 7))
        #expect(entry.cost == 0.31)
        #expect(entry.date == Date(timeIntervalSince1970: t - 100))
    }

    @Test func aSessionThatSwitchedModelsYieldsOneEntryPerMessage() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(model: ("gpt-6-sol", "openai", "default"), input: 10, created: t - 200)
        fixture.insertMessage(model: ("gpt-6-luna", "openai", "xhigh"), input: 20, created: t - 100)

        let models = try usage(fixture).compactMap(\.model?.id).sorted()
        #expect(models == ["gpt-6-luna", "gpt-6-sol"])
    }

    @Test func ignoresNonAssistantMessagesAndEmptyOnes() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(type: "user", input: 5, created: t - 100)
        fixture.insertMessage(type: "compaction", input: 5, created: t - 100)
        fixture.insertMessage(input: 0, output: 0, created: t - 100)
        fixture.insertMessage(input: 1, created: t - 100)

        #expect(try usage(fixture).count == 1)
    }

    @Test func zeroCostMeansUnpriced() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(input: 1, cost: 0, created: t - 100)

        #expect(try usage(fixture).first?.cost == nil)
    }

    @Test func excludesMessagesBeforeTheRequestedStart() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(input: 1, created: t - 7200)
        fixture.insertMessage(input: 2, created: t - 60)

        let entries = try usage(fixture, since: now.addingTimeInterval(-3600))
        #expect(entries.map(\.usage.input) == [2])
    }

    @Test func aMessageWithoutAModelStillCounts() throws {
        let fixture = try OpenCodeFixture()
        fixture.insertMessage(model: nil, input: 3, created: t - 60)

        let entry = try #require(try usage(fixture).first)
        #expect(entry.model == nil)
        #expect(entry.usage.input == 3)
    }

    @Test func missingDatabaseThrowsDataNotFound() {
        let source = OpenCodeSource(databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db"))

        #expect {
            try source.fetchUsage(since: .distantPast)
        } throws: { error in
            if case AgentSourceError.dataNotFound = error { true } else { false }
        }
    }
}
