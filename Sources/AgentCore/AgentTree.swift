import Foundation

public struct AgentNode: Sendable, Equatable {
    public let agent: Agent
    public let children: [AgentNode]
}

public enum AgentTree {
    /// Nests subagents under their parent session. A subagent whose parent is
    /// not in `agents` becomes a top-level node so it is never hidden.
    /// Siblings are ordered newest first.
    public static func build(_ agents: [Agent]) -> [AgentNode] {
        let ids = Set(agents.map(\.id))
        let byParent = Dictionary(grouping: agents.filter { agent in
            agent.parentSessionID.map(ids.contains) ?? false
        }, by: { $0.parentSessionID! })

        func node(for agent: Agent) -> AgentNode {
            AgentNode(agent: agent, children: sorted(byParent[agent.id] ?? []).map(node))
        }

        let roots = agents.filter { agent in
            agent.parentSessionID.map { !ids.contains($0) } ?? true
        }
        return sorted(roots).map(node)
    }

    private static func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted { $0.startedAt > $1.startedAt }
    }
}
