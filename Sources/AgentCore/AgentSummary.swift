import Foundation

/// What the menu bar icon shows at a glance.
public struct AgentSummary: Sendable, Equatable {
    public let runningSessions: Int
    public let runningSubagents: Int

    public var totalRunning: Int { runningSessions + runningSubagents }

    /// e.g. "1 session · 0 subagents running"
    public var text: String {
        let sessions = runningSessions == 1 ? "session" : "sessions"
        let subagents = runningSubagents == 1 ? "subagent" : "subagents"
        return "\(runningSessions) \(sessions) · \(runningSubagents) \(subagents) running"
    }

    public init(_ agents: [Agent]) {
        let running = agents.filter { $0.status == .running }
        runningSessions = running.filter(\.isMainSession).count
        runningSubagents = running.count - runningSessions
    }
}
