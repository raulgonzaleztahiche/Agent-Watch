import AgentCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)

private func agent(
    parent: String? = "main", status: AgentStatus, started: TimeInterval, updated: TimeInterval
) -> Agent {
    Agent(
        id: "x", tool: .openCode, parentSessionID: parent, name: "x", title: nil, model: nil, status: status,
        startedAt: now.addingTimeInterval(-started), updatedAt: now.addingTimeInterval(-updated))
}

@Suite struct DurationFormatTests {
    @Test(arguments: [
        (0.0, "0s"), (45, "45s"), (59.9, "59s"), (60, "1m"), (125, "2m 5s"), (3_599, "59m 59s"),
        (3_600, "1h"), (4_320, "1h 12m"), (86_399, "23h 59m"), (86_400, "1d"), (90_000, "1d 1h"),
    ])
    func formatsDurations(seconds: Double, expected: String) {
        #expect(ActivityLabel.duration(seconds) == expected)
    }

    @Test func negativeDurationsClampToZero() {
        #expect(ActivityLabel.duration(-5) == "0s")
        #expect(ActivityLabel.ago(-5) == "just now")
    }

    @Test(arguments: [
        (0.0, "just now"), (9, "just now"), (10, "10s ago"), (59, "59s ago"), (60, "1m ago"),
        (3_599, "59m ago"), (3_600, "1h ago"), (86_399, "23h ago"), (86_400, "1d ago"), (260_000, "3d ago"),
    ])
    func formatsHowLongAgo(seconds: Double, expected: String) {
        #expect(ActivityLabel.ago(seconds) == expected)
    }
}

@Suite struct ActivityLabelTests {
    @Test func runningSubagentShowsHowLongItHasBeenRunning() {
        let sub = agent(status: .running, started: 80, updated: 2)

        #expect(ActivityLabel.text(for: sub, now: now) == "running 1m 20s")
    }

    @Test func finishedSubagentShowsItsDurationNotTheTimeSinceStart() {
        // Started 1h ago, ran 125 s, finished long ago: the label must say how long it took.
        let sub = agent(status: .succeeded, started: 3_600, updated: 3_600 - 125)

        #expect(ActivityLabel.text(for: sub, now: now) == "took 2m 5s")
    }

    @Test func failedAndInterruptedSubagentsSayHowLongTheyLasted() {
        #expect(ActivityLabel.text(for: agent(status: .failed, started: 500, updated: 440), now: now)
            == "failed after 1m")
        #expect(ActivityLabel.text(for: agent(status: .interrupted, started: 500, updated: 320), now: now)
            == "stopped after 3m")
    }

    @Test func mainSessionsShowLastActivityWhateverTheirStatus() {
        for status in [AgentStatus.running, .idle, .succeeded, .unknown] {
            let main = agent(parent: nil, status: status, started: 36_000, updated: 180)

            #expect(ActivityLabel.text(for: main, now: now) == "3m ago")
        }
    }

    @Test func staleSubagentWithoutAFinalSignalShowsLastActivity() {
        let sub = agent(status: .unknown, started: 90_000, updated: 7_300)

        #expect(ActivityLabel.text(for: sub, now: now) == "2h ago")
    }
}
