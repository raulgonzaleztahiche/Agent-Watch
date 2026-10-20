import AgentCore
import Foundation
import Testing

private func agent(
    _ id: String, parent: String? = nil, status: AgentStatus = .idle, startedAt minutes: Double = 0
) -> Agent {
    let date = Date(timeIntervalSince1970: minutes * 60)
    return Agent(
        id: id, tool: .openCode, parentSessionID: parent, name: "x", title: nil,
        model: nil, status: status, startedAt: date, updatedAt: date
    )
}

@Suite struct AgentSummaryTests {
    @Test func countsOnlyRunningAgentsSplitBySessionAndSubagent() {
        let summary = AgentSummary([
            agent("main1", status: .running),
            agent("main2", status: .idle),
            agent("sub1", parent: "main1", status: .running),
            agent("sub2", parent: "main1", status: .running),
            agent("sub3", parent: "main1", status: .succeeded),
        ])

        #expect(summary.runningSessions == 1)
        #expect(summary.runningSubagents == 2)
        #expect(summary.totalRunning == 3)
    }

    @Test func emptyListHasNothingRunning() {
        #expect(AgentSummary([]).totalRunning == 0)
    }
}

@Suite struct AgentRowsTests {
    @Test func listsEachSessionFollowedByItsSubagentsWithDepth() {
        let rows = AgentTree.rows([
            agent("old", startedAt: 1),
            agent("new", startedAt: 5),
            agent("sub-b", parent: "new", startedAt: 7),
            agent("sub-a", parent: "new", startedAt: 6),
            agent("subsub", parent: "sub-a", startedAt: 8),
        ])

        #expect(rows.map(\.agent.id) == ["new", "sub-b", "sub-a", "subsub", "old"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0])
    }

    @Test func rowIDsStayUniqueAcrossToolsWithTheSameSessionID() {
        let first = AgentRow(agent: agent("same"), depth: 0)
        let second = AgentRow(
            agent: Agent(
                id: "same", tool: .claudeCode, parentSessionID: nil, name: "x", title: nil,
                model: nil, status: .idle, startedAt: .now, updatedAt: .now),
            depth: 0)

        #expect(first.id != second.id)
    }
}

@Suite struct TitleFormatterTests {
    @Test func dropsLegacySubagentSuffix() {
        #expect(TitleFormatter.clean("Map checkout (@explore subagent)") == "Map checkout")
    }

    @Test func keepsOnlyTheFirstLine() {
        #expect(TitleFormatter.clean("First\nSecond") == "First")
    }

    @Test func truncatesLongTitlesWithAnEllipsis() {
        let result = TitleFormatter.clean(String(repeating: "a", count: 100), maxLength: 10)

        #expect(result == "aaaaaaaaa…")
    }

    @Test func nilTitleBecomesEmpty() {
        #expect(TitleFormatter.clean(nil) == "")
    }
}

private final class FakeSource: AgentSource {
    let tool: AgentTool
    let result: Result<[Agent], AgentSourceError>

    init(tool: AgentTool, result: Result<[Agent], AgentSourceError>) {
        self.tool = tool
        self.result = result
    }

    func fetchAgents(updatedSince: Date, now: Date) throws -> [Agent] { try result.get() }
}

@Suite struct AgentRepositoryTests {
    @Test func aFailingSourceDoesNotHideTheOthers() async {
        let repository = AgentRepository {
            [
                FakeSource(tool: .claudeCode, result: .failure(.dataNotFound("~/.claude"))),
                FakeSource(tool: .openCode, result: .success([agent("ok")])),
            ]
        }

        let result = await repository.fetch(window: 3600)

        #expect(result.agents.map(\.id) == ["ok"])
        #expect(result.errors.count == 1)
        #expect(result.errors[0].hasPrefix("claude-code:"))
    }

    @Test func passesTheWindowStartToEverySource() async {
        final class Recorder: AgentSource, @unchecked Sendable {
            let tool = AgentTool.openCode
            nonisolated(unsafe) var since: Date?
            func fetchAgents(updatedSince: Date, now: Date) throws -> [Agent] {
                since = updatedSince
                return []
            }
        }
        let recorder = Recorder()
        let repository = AgentRepository { [recorder] }
        let now = Date(timeIntervalSince1970: 10_000)

        _ = await repository.fetch(window: 3600, now: now)

        #expect(recorder.since == now.addingTimeInterval(-3600))
    }
}

@Suite struct TokenUsageTests {
    @Test(arguments: [
        (0, "0"), (950, "950"), (1_000, "1k"), (1_234, "1.2k"), (27_161, "27.2k"),
        (999_949, "999.9k"), (999_950, "1M"), (10_280_704, "10.3M"), (1_500_000_000, "1.5B"),
    ])
    func compactsCounts(count: Int, expected: String) {
        #expect(TokenUsage.compact(count) == expected)
    }

    @Test func summaryShowsInputAndOutputOnly() {
        let usage = TokenUsage(input: 697_449, output: 27_161, reasoning: 23_784, cacheRead: 10_280_704)

        #expect(usage.summary == "697.4k in · 27.2k out")
    }

    @Test func emptyUsageIsEmpty() {
        #expect(TokenUsage().isEmpty)
        #expect(!TokenUsage(output: 1).isEmpty)
    }

    @Test func addsEveryCounter() {
        let sum = TokenUsage(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite: 5)
            + TokenUsage(input: 10, output: 20, reasoning: 30, cacheRead: 40, cacheWrite: 50)

        #expect(sum == TokenUsage(input: 11, output: 22, reasoning: 33, cacheRead: 44, cacheWrite: 55))
    }
}
