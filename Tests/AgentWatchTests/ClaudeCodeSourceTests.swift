import Adapters
import AgentCore
import Foundation
import Testing

/// Builds a throwaway `~/.claude/projects` tree with one project.
private final class ClaudeFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentwatch-cc-\(UUID().uuidString)")
        project = root.appendingPathComponent("-Users-someone-code-demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func source() -> ClaudeCodeSource { ClaudeCodeSource(projectsRoot: root) }

    @discardableResult
    func writeMainSession(_ sessionID: String, rows: [[String: Any]]) throws -> URL {
        let url = project.appendingPathComponent("\(sessionID).jsonl")
        try write(rows, to: url)
        return url
    }

    @discardableResult
    func writeSubagent(
        _ agentID: String, session sessionID: String, rows: [[String: Any]], meta: [String: Any]
    ) throws -> URL {
        let directory = project.appendingPathComponent("\(sessionID)/subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent-\(agentID).jsonl")
        try write(rows, to: url)
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: directory.appendingPathComponent("agent-\(agentID).meta.json"))
        return url
    }

    func write(_ rows: [[String: Any]], to url: URL) throws {
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ rows: [[String: Any]], to url: URL) throws {
        let existing = try String(contentsOf: url, encoding: .utf8)
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (existing + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private let now = Date(timeIntervalSince1970: 1_000_000)
private let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

private func stamp(_ secondsAgo: Double) -> String {
    now.addingTimeInterval(-secondsAgo).formatted(iso)
}

// Row builders mirroring the real JSONL shapes.
private func user(_ session: String, _ secondsAgo: Double, agent: String? = nil) -> [String: Any] {
    var row: [String: Any] = ["type": "user", "sessionId": session, "timestamp": stamp(secondsAgo),
                              "message": ["role": "user", "content": "hi"]]
    if let agent { row["agentId"] = agent }
    return row
}

private func assistant(
    _ session: String, _ secondsAgo: Double, model: String = "claude-sonnet-5-5",
    stop: String, agent: String? = nil
) -> [String: Any] {
    var row: [String: Any] = ["type": "assistant", "sessionId": session, "timestamp": stamp(secondsAgo),
                              "message": ["model": model, "stop_reason": stop]]
    if let agent { row["agentId"] = agent }
    return row
}

private func usageRow(
    _ session: String, _ secondsAgo: Double, messageID: String,
    input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0, thinking: Int = 0
) -> [String: Any] {
    ["type": "assistant", "sessionId": session, "timestamp": stamp(secondsAgo),
     "message": ["id": messageID, "model": "claude-sonnet-5-5", "stop_reason": "end_turn",
                 "usage": ["input_tokens": input, "output_tokens": output,
                           "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
                           "output_tokens_details": ["thinking_tokens": thinking]]]]
}

private func fetch(_ fixture: ClaudeFixture, since: Date = .distantPast) throws -> [String: Agent] {
    let agents = try fixture.source().fetchAgents(updatedSince: since, now: now)
    return Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
}

@Suite struct ClaudeCodeMainSessionTests {
    @Test func waitingOnToolIsRunningWhileRecent() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [user("s1", 30), assistant("s1", 10, stop: "tool_use")])

        #expect(try fetch(fixture)["s1"]?.status == .running)
    }

    @Test func endTurnIsIdle() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [user("s1", 30), assistant("s1", 10, stop: "end_turn")])

        #expect(try fetch(fixture)["s1"]?.status == .idle)
    }

    @Test func userMessageAfterEndTurnIsRunning() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [assistant("s1", 30, stop: "end_turn"), user("s1", 5)])

        #expect(try fetch(fixture)["s1"]?.status == .running)
    }

    @Test func staleToolUseIsIdle() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [assistant("s1", 3600, stop: "tool_use")])

        #expect(try fetch(fixture)["s1"]?.status == .idle)
    }

    @Test func modelComesFromAssistantRowsOnly() throws {
        // Real transcripts contain request rows that mention other models.
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [
            assistant("s1", 20, model: "claude-haiku-5-5", stop: "end_turn"),
            ["type": "api-request", "sessionId": "s1", "timestamp": stamp(10), "model": "claude-opus-5-5"],
        ])

        let session = try #require(try fetch(fixture)["s1"])
        #expect(session.model == ModelRef(provider: "anthropic", id: "claude-haiku-5-5", variant: nil))
        #expect(session.isMainSession)
        #expect(session.name == "main")
        #expect(session.tool == .claudeCode)
    }

    @Test func titlePrefersCustomThenAiThenLastPrompt() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("custom", rows: [
            user("custom", 10),
            ["type": "last-prompt", "lastPrompt": "prompt", "sessionId": "custom"],
            ["type": "ai-title", "aiTitle": "ai", "sessionId": "custom"],
            ["type": "custom-title", "customTitle": "mine", "sessionId": "custom"],
        ])
        try fixture.writeMainSession("ai", rows: [
            user("ai", 10),
            ["type": "last-prompt", "lastPrompt": "prompt", "sessionId": "ai"],
            ["type": "ai-title", "aiTitle": "ai", "sessionId": "ai"],
        ])
        try fixture.writeMainSession("prompt", rows: [
            user("prompt", 10),
            ["type": "last-prompt", "lastPrompt": "prompt", "sessionId": "prompt"],
        ])

        let agents = try fetch(fixture)
        #expect(agents["custom"]?.title == "mine")
        #expect(agents["ai"]?.title == "ai")
        #expect(agents["prompt"]?.title == "prompt")
    }

    @Test func excludesTranscriptsNotModifiedInWindow() throws {
        let fixture = try ClaudeFixture()
        let old = try fixture.writeMainSession("old", rows: [user("old", 10)])
        try fixture.writeMainSession("new", rows: [user("new", 10)])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)

        let agents = try fixture.source().fetchAgents(updatedSince: Date().addingTimeInterval(-3600), now: now)
        #expect(agents.map(\.id) == ["new"])
    }

    @Test func rereadsTranscriptWhenItChanges() throws {
        // The app polls with one source instance; the cache must not hide new rows.
        let fixture = try ClaudeFixture()
        let url = try fixture.writeMainSession("s1", rows: [assistant("s1", 30, stop: "tool_use")])
        let source = fixture.source()
        #expect(try source.fetchAgents(updatedSince: .distantPast, now: now).first?.status == .running)

        try fixture.append([assistant("s1", 5, stop: "end_turn")], to: url)

        #expect(try source.fetchAgents(updatedSince: .distantPast, now: now).first?.status == .idle)
    }
}

@Suite struct ClaudeCodeDirectoryTests {
    @Test func takesTheProjectFromTheLatestCwdOfTheTranscript() throws {
        let fixture = try ClaudeFixture()
        // A session can start in a scratch folder and move to the real project.
        var first = user("s1", 30)
        first["cwd"] = "/Users/me/scratch-2026-10-20"
        var later = assistant("s1", 10, stop: "end_turn")
        later["cwd"] = "/Users/me/code/barracuda"
        let noCwd = user("s1", 5)
        try fixture.writeMainSession("s1", rows: [first, later, noCwd])

        let session = try #require(try fetch(fixture)["s1"])
        #expect(session.directory == "/Users/me/code/barracuda")
        #expect(session.projectName == "barracuda")
    }

    @Test func subagentsCarryTheirOwnCwd() throws {
        let fixture = try ClaudeFixture()
        var row = user("s1", 20, agent: "a1")
        row["cwd"] = "/Users/me/code/demo"
        try fixture.writeSubagent(
            "a1", session: "s1", rows: [row, assistant("s1", 10, stop: "end_turn", agent: "a1")],
            meta: ["agentType": "Explore", "toolUseId": "t"])

        #expect(try fetch(fixture)["a1"]?.projectName == "demo")
    }

    @Test func missingCwdMeansNoProject() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [user("s1", 10)])

        #expect(try fetch(fixture)["s1"]?.directory == nil)
    }
}

@Suite struct ClaudeCodeUsageTests {
    @Test func countsRepeatedContentBlocksOfOneMessageOnce() throws {
        // Real transcripts write one row per content block with identical usage.
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [
            usageRow("s1", 30, messageID: "m1", input: 2, output: 551),
            usageRow("s1", 29, messageID: "m1", input: 2, output: 551),
            usageRow("s1", 28, messageID: "m1", input: 2, output: 551),
        ])

        #expect(try fetch(fixture)["s1"]?.usage == TokenUsage(input: 2, output: 551))
    }

    @Test func sumsDistinctMessagesAndAllCounters() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [
            usageRow("s1", 30, messageID: "m1", input: 2, output: 100, cacheRead: 1000, cacheWrite: 50, thinking: 7),
            usageRow("s1", 20, messageID: "m2", input: 3, output: 200, cacheRead: 2000, cacheWrite: 0, thinking: 3),
        ])

        #expect(try fetch(fixture)["s1"]?.usage == TokenUsage(
            input: 5, output: 300, reasoning: 10, cacheRead: 3000, cacheWrite: 50))
    }

    @Test func rowsWithoutUsageGiveNoUsageAndNoCost() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [assistant("s1", 10, stop: "end_turn")])

        let session = try #require(try fetch(fixture)["s1"])
        #expect(session.usage == nil)
        #expect(session.cost == nil)
    }
}

@Suite struct ClaudeCodeSubagentTests {
    private func subagentRows(_ agent: String, lastActivity secondsAgo: Double) -> [[String: Any]] {
        [user("s1", secondsAgo + 20, agent: agent),
         assistant("s1", secondsAgo, model: "claude-haiku-5-5", stop: "tool_use", agent: agent)]
    }

    private let meta: [String: Any] = [
        "agentType": "Explore", "description": "Map the flow", "toolUseId": "toolu_1",
    ]

    @Test func resultInParentTranscriptMeansSucceeded() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [
            assistant("s1", 40, stop: "tool_use"),
            ["type": "user", "sessionId": "s1", "timestamp": stamp(1),
             "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1"]]]],
        ])
        try fixture.writeSubagent("a1", session: "s1", rows: subagentRows("a1", lastActivity: 5), meta: meta)

        #expect(try fetch(fixture)["a1"]?.status == .succeeded)
    }

    @Test func noResultYetIsRunningWhileRecent() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeMainSession("s1", rows: [assistant("s1", 40, stop: "tool_use")])
        try fixture.writeSubagent("a1", session: "s1", rows: subagentRows("a1", lastActivity: 5), meta: meta)

        #expect(try fetch(fixture)["a1"]?.status == .running)
    }

    @Test func noResultAndStaleIsUnknown() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeSubagent("a1", session: "s1", rows: subagentRows("a1", lastActivity: 3600), meta: meta)

        #expect(try fetch(fixture)["a1"]?.status == .unknown)
    }

    @Test func finishedFlagInMetaMeansSucceeded() throws {
        let fixture = try ClaudeFixture()
        var finishedMeta = meta
        finishedMeta["finished"] = true
        try fixture.writeSubagent("a1", session: "s1", rows: subagentRows("a1", lastActivity: 5), meta: finishedMeta)

        #expect(try fetch(fixture)["a1"]?.status == .succeeded)
    }

    @Test func mapsIdentityFromMetaAndTranscript() throws {
        let fixture = try ClaudeFixture()
        try fixture.writeSubagent("a1", session: "s1", rows: subagentRows("a1", lastActivity: 5), meta: meta)

        let sub = try #require(try fetch(fixture)["a1"])
        #expect(sub.parentSessionID == "s1")
        #expect(sub.name == "Explore")
        #expect(sub.title == "Map the flow")
        #expect(sub.model == ModelRef(provider: "anthropic", id: "claude-haiku-5-5", variant: nil))
        #expect(sub.startedAt == now.addingTimeInterval(-25))
        #expect(sub.updatedAt == now.addingTimeInterval(-5))
    }

    @Test func missingProjectsRootThrowsDataNotFound() {
        let source = ClaudeCodeSource(projectsRoot: URL(fileURLWithPath: "/nonexistent/projects"))

        #expect {
            try source.fetchAgents(updatedSince: .distantPast, now: now)
        } throws: { error in
            if case AgentSourceError.dataNotFound = error { true } else { false }
        }
    }
}
