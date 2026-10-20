import Foundation

public struct AgentEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case finished
        case failed
        case interrupted
    }

    public let agent: Agent
    public let kind: Kind

    public init(agent: Agent, kind: Kind) {
        self.agent = agent
        self.kind = kind
    }

    /// Failures and interruptions always deserve attention; a clean finish is optional.
    public var isAlert: Bool { kind != .finished }

    public var title: String {
        switch kind {
        case .finished: "Subagent finished"
        case .failed: "Subagent failed"
        case .interrupted: "Subagent interrupted"
        }
    }

    /// e.g. "explore · openai/gpt-6-luna (high)\nMap flow"
    public var body: String {
        let who = [agent.name, agent.model?.displayName].compactMap { $0 }.joined(separator: " · ")
        let task = TitleFormatter.clean(agent.title, maxLength: 80)
        return task.isEmpty ? who : "\(who)\n\(task)"
    }
}

/// Turns successive snapshots into events. Only a subagent seen `running` that is later
/// seen in a final state produces an event, so opening the app never replays history.
public struct TransitionDetector: Sendable {
    private var lastStatus: [String: AgentStatus] = [:]

    public init() {}

    public mutating func observe(_ agents: [Agent]) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for agent in agents where !agent.isMainSession {
            guard lastStatus[agent.key] == .running, let kind = Self.kind(for: agent.status) else { continue }
            events.append(AgentEvent(agent: agent, kind: kind))
        }
        lastStatus = Dictionary(agents.map { ($0.key, $0.status) }, uniquingKeysWith: { _, latest in latest })
        return events
    }

    private static func kind(for status: AgentStatus) -> AgentEvent.Kind? {
        switch status {
        case .succeeded: .finished
        case .failed: .failed
        case .interrupted: .interrupted
        case .running, .idle, .unknown: nil
        }
    }
}
