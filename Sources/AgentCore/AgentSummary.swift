import Foundation

/// What the menu bar icon shows at a glance.
public struct AgentSummary: Sendable, Equatable {
    public let runningSessions: Int
    public let runningSubagents: Int

    public var totalRunning: Int { runningSessions + runningSubagents }

    public init(_ agents: [Agent]) {
        let running = agents.filter { $0.status == .running }
        runningSessions = running.filter(\.isMainSession).count
        runningSubagents = running.count - runningSessions
    }
}
