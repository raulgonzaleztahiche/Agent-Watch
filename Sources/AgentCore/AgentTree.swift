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

/// The list as the user reads it: what works now, what is open and waiting, and the history.
public struct AgentSections: Sendable, Equatable {
    public let running: [AgentRow]
    /// Not running, but with activity within `ActivityPolicy.activeWindow`.
    public let active: [AgentRow]
    public let recent: [AgentRow]
    /// Number of top-level entries in `active` and `recent` (what the user sees as "N").
    public let activeTreeCount: Int
    public let recentTreeCount: Int

    public init(
        running: [AgentRow], active: [AgentRow], recent: [AgentRow], activeTreeCount: Int, recentTreeCount: Int
    ) {
        self.running = running
        self.active = active
        self.recent = recent
        self.activeTreeCount = activeTreeCount
        self.recentTreeCount = recentTreeCount
    }

    public static let empty = AgentSections(
        running: [], active: [], recent: [], activeTreeCount: 0, recentTreeCount: 0)

    public var isEmpty: Bool { running.isEmpty && active.isEmpty && recent.isEmpty }
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
        build(agents).flatMap { flatten($0, depth: 0) }
    }

    /// Splits the trees by how alive they are. A tree is running when any of its agents is,
    /// so an idle session stays with its running subagent; otherwise it is active when anything
    /// in it was touched within `ActivityPolicy.activeWindow`, and recent when not.
    public static func sections(_ agents: [Agent], now: Date = Date()) -> AgentSections {
        let nodes = build(agents)
        let running = nodes.filter(isRunning)
        let waiting = nodes.filter { !isRunning($0) }
        let active = waiting.filter { ActivityPolicy.isActive(lastActivity($0), now: now) }
        let recent = waiting.filter { !ActivityPolicy.isActive(lastActivity($0), now: now) }
        return AgentSections(
            running: running.flatMap { flatten($0, depth: 0) },
            active: active.flatMap { flatten($0, depth: 0) },
            recent: recent.flatMap { flatten($0, depth: 0) },
            activeTreeCount: active.count,
            recentTreeCount: recent.count
        )
    }

    private static func isRunning(_ node: AgentNode) -> Bool {
        node.agent.status == .running || node.children.contains(where: isRunning)
    }

    private static func lastActivity(_ node: AgentNode) -> Date {
        node.children.map(lastActivity).reduce(node.agent.updatedAt, max)
    }

    private static func flatten(_ node: AgentNode, depth: Int) -> [AgentRow] {
        [AgentRow(agent: node.agent, depth: depth)]
            + node.children.flatMap { flatten($0, depth: depth + 1) }
    }

    private static func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted { $0.startedAt > $1.startedAt }
    }
}
