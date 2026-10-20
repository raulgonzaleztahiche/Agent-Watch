import AgentCore
import Foundation
import Testing

private func agent(
    _ id: String, parent: String? = "main", status: AgentStatus, tool: AgentTool = .openCode
) -> Agent {
    Agent(
        id: id, tool: tool, parentSessionID: parent, name: "explore", title: "Map flow",
        model: nil, status: status, startedAt: .now, updatedAt: .now
    )
}

@Suite struct TransitionDetectorTests {
    @Test(arguments: [
        (AgentStatus.succeeded, AgentEvent.Kind.finished),
        (.failed, .failed),
        (.interrupted, .interrupted),
    ])
    func reportsARunningSubagentReachingAFinalState(status: AgentStatus, kind: AgentEvent.Kind) {
        var detector = TransitionDetector()
        _ = detector.observe([agent("sub", status: .running)])

        let events = detector.observe([agent("sub", status: status)])

        #expect(events.map(\.kind) == [kind])
        #expect(events.first?.agent.id == "sub")
    }

    @Test func staysSilentOnTheFirstSnapshotEvenIfAgentsAlreadyFailed() {
        // Opening the app must not replay history.
        var detector = TransitionDetector()

        let events = detector.observe([agent("old", status: .failed), agent("done", status: .succeeded)])

        #expect(events.isEmpty)
    }

    @Test func reportsEachTransitionOnlyOnce() {
        var detector = TransitionDetector()
        _ = detector.observe([agent("sub", status: .running)])
        _ = detector.observe([agent("sub", status: .failed)])

        #expect(detector.observe([agent("sub", status: .failed)]).isEmpty)
    }

    @Test func ignoresASubagentGoingStaleWithoutAFinalSignal() {
        var detector = TransitionDetector()
        _ = detector.observe([agent("sub", status: .running)])

        #expect(detector.observe([agent("sub", status: .unknown)]).isEmpty)
    }

    @Test func ignoresMainSessionsGoingIdle() {
        var detector = TransitionDetector()
        _ = detector.observe([agent("main", parent: nil, status: .running)])

        #expect(detector.observe([agent("main", parent: nil, status: .idle)]).isEmpty)
    }

    @Test func keepsSameIDInDifferentToolsApart() {
        var detector = TransitionDetector()
        _ = detector.observe([agent("same", status: .running, tool: .openCode)])

        let events = detector.observe([agent("same", status: .failed, tool: .claudeCode)])

        #expect(events.isEmpty)
    }

    @Test func reportsSeveralSubagentsFinishingTogether() {
        var detector = TransitionDetector()
        _ = detector.observe([agent("a", status: .running), agent("b", status: .running)])

        let events = detector.observe([agent("a", status: .succeeded), agent("b", status: .failed)])

        #expect(Set(events.map(\.agent.id)) == ["a", "b"])
    }

    @Test func onlyFailuresAndInterruptionsAreAlerts() {
        let sub = agent("sub", status: .failed)

        #expect(AgentEvent(agent: sub, kind: .failed).isAlert)
        #expect(AgentEvent(agent: sub, kind: .interrupted).isAlert)
        #expect(!AgentEvent(agent: sub, kind: .finished).isAlert)
    }

    @Test func messageNamesTheAgentModelAndTask() {
        let sub = Agent(
            id: "sub", tool: .openCode, parentSessionID: "main", name: "explore", title: "Map flow (@explore subagent)",
            model: ModelRef(provider: "openai", id: "gpt-6-luna", variant: "high"), status: .failed,
            startedAt: .now, updatedAt: .now)
        let event = AgentEvent(agent: sub, kind: .failed)

        #expect(event.title == "Subagent failed")
        #expect(event.body == "explore · openai/gpt-6-luna (high)\nMap flow")
    }

    @Test func messageOmitsMissingModelAndTitle() {
        let sub = Agent(
            id: "sub", tool: .claudeCode, parentSessionID: "main", name: "Explore", title: nil,
            model: nil, status: .succeeded, startedAt: .now, updatedAt: .now)

        #expect(AgentEvent(agent: sub, kind: .finished).body == "Explore")
        #expect(AgentEvent(agent: sub, kind: .finished).title == "Subagent finished")
        #expect(AgentEvent(agent: sub, kind: .interrupted).title == "Subagent interrupted")
    }
}
