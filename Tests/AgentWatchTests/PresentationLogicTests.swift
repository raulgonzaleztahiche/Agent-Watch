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

    @Test func textUsesSingularForOneAndPluralOtherwise() {
        let one = AgentSummary([agent("m", status: .running), agent("s", parent: "m", status: .running)])
        let many = AgentSummary([
            agent("a", status: .running), agent("b", status: .running),
            agent("s1", parent: "a", status: .running), agent("s2", parent: "a", status: .running),
        ])

        #expect(one.text == "1 session · 1 subagent running")
        #expect(many.text == "2 sessions · 2 subagents running")
        #expect(AgentSummary([]).text == "0 sessions · 0 subagents running")
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

@Suite struct AgentSectionsTests {
    /// `agent(...)` stamps both dates with `startedAt`, so a test controls recency through it.
    private let now = Date(timeIntervalSince1970: 100 * 60)

    @Test func separatesRunningActiveAndRecentTrees() {
        let sections = AgentTree.sections([
            agent("busy", status: .running, startedAt: 99),
            agent("waiting", status: .idle, startedAt: 90),
            agent("old", status: .idle, startedAt: 10),
            agent("old-sub", parent: "old", status: .succeeded, startedAt: 11),
        ], now: now)

        #expect(sections.running.map(\.agent.id) == ["busy"])
        #expect(sections.active.map(\.agent.id) == ["waiting"])
        #expect(sections.recent.map(\.agent.id) == ["old", "old-sub"])
        #expect(sections.activeTreeCount == 1)
        #expect(sections.recentTreeCount == 1)
    }

    @Test func idleSessionWithARunningSubagentIsRunningAsAWhole() {
        let sections = AgentTree.sections([
            agent("main", status: .idle, startedAt: 1),
            agent("sub", parent: "main", status: .running, startedAt: 2),
            agent("old-sub", parent: "main", status: .succeeded, startedAt: 3),
        ], now: now)

        #expect(sections.running.map(\.agent.id) == ["main", "old-sub", "sub"])
        #expect(sections.running.map(\.depth) == [0, 1, 1])
        #expect(sections.active.isEmpty && sections.recent.isEmpty)
    }

    @Test func aRunningGrandchildMakesTheWholeTreeRunning() {
        let sections = AgentTree.sections([
            agent("main", status: .idle, startedAt: 1),
            agent("child", parent: "main", status: .succeeded, startedAt: 2),
            agent("grandchild", parent: "child", status: .running, startedAt: 3),
        ], now: now)

        #expect(sections.running.count == 3)
    }

    @Test func aRecentSubagentKeepsAnOldSessionActive() {
        // Activity anywhere in the tree counts, not only the root's.
        let sections = AgentTree.sections([
            agent("main", status: .idle, startedAt: 1),
            agent("sub", parent: "main", status: .succeeded, startedAt: 95),
        ], now: now)

        #expect(sections.active.map(\.agent.id) == ["main", "sub"])
        #expect(sections.recent.isEmpty)
    }

    @Test func activityExactlyAtTheWindowEdgeIsRecent() {
        let edge = 100.0 - ActivityPolicy.activeWindow / 60
        let sections = AgentTree.sections([agent("a", status: .idle, startedAt: edge)], now: now)

        #expect(sections.active.isEmpty)
        #expect(sections.recentTreeCount == 1)
    }

    @Test func staleAndFailedAgentsAreRecent() {
        let sections = AgentTree.sections([
            agent("a", status: .unknown, startedAt: 1),
            agent("b", status: .failed, startedAt: 2),
        ], now: now)

        #expect(sections.running.isEmpty && sections.active.isEmpty)
        #expect(sections.recentTreeCount == 2)
    }

    @Test func noAgentsGivesEmptySections() {
        #expect(AgentTree.sections([], now: now) == .empty)
        #expect(AgentSections.empty.isEmpty)
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
