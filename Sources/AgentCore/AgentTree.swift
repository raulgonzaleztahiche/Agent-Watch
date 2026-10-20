import Foundation

public struct AgentNode: Sendable, Equatable {
    public let agent: Agent
    public let children: [AgentNode]
}

/// One line of the flattened tree, ready for a list.
public struct AgentRow: Sendable, Equatable, Identifiable {
    public let agent: Agent
    public let depth: Int
    public var id: String { agent.key }

    public init(agent: Agent, depth: Int) {
        self.agent = agent
        self.depth = depth
    }
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

    /// Depth-first rows: each session followed by its subagents.
    public static func rows(_ agents: [Agent]) -> [AgentRow] {
        func flatten(_ node: AgentNode, depth: Int) -> [AgentRow] {
            [AgentRow(agent: node.agent, depth: depth)]
                + node.children.flatMap { flatten($0, depth: depth + 1) }
        }
        return build(agents).flatMap { flatten($0, depth: 0) }
    }

    private static func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted { $0.startedAt > $1.startedAt }
    }
}
