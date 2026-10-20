import Foundation

public enum AgentTool: String, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case openCode = "opencode"
}

public enum AgentStatus: String, Sendable {
    case running
    /// Main session waiting for the user.
    case idle
    case succeeded
    case failed
    case interrupted
    /// No terminal signal and no recent activity.
    case unknown
}

public struct ModelRef: Sendable, Equatable {
    public let provider: String?
    public let id: String
    public let variant: String?

    public init(provider: String?, id: String, variant: String?) {
        self.provider = provider
        self.id = id
        self.variant = variant
    }

    public var displayName: String {
        var text = provider.map { "\($0)/\(id)" } ?? id
        if let variant, variant != "default" { text += " (\(variant))" }
        return text
    }
}

/// A main session or a subagent. Subagents point to the session that launched them.
public struct Agent: Sendable, Equatable, Identifiable {
    public let id: String
    public let tool: AgentTool
    /// `nil` for a main session.
    public let parentSessionID: String?
    /// Agent type, e.g. "Explore" or "gentle-ai-verify".
    public let name: String
    /// Session title or the task description given at launch.
    public let title: String?
    public let model: ModelRef?
    public let status: AgentStatus
    public let startedAt: Date
    public let updatedAt: Date
    /// Tokens used by this session or subagent alone (children are not included).
    public let usage: TokenUsage?
    /// Cost in USD as reported by the tool. `nil` when the tool does not report it
    /// (Claude Code) or reports zero (subscription plans); never estimated.
    public let cost: Double?

    public var isMainSession: Bool { parentSessionID == nil }

    /// Unique across tools, since two tools could reuse the same session id.
    public var key: String { "\(tool.rawValue):\(id)" }

    public init(
        id: String,
        tool: AgentTool,
        parentSessionID: String?,
        name: String,
        title: String?,
        model: ModelRef?,
        status: AgentStatus,
        startedAt: Date,
        updatedAt: Date,
        usage: TokenUsage? = nil,
        cost: Double? = nil
    ) {
        self.id = id
        self.tool = tool
        self.parentSessionID = parentSessionID
        self.name = name
        self.title = title
        self.model = model
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.usage = usage
        self.cost = cost
    }
}

public enum ActivityPolicy {
    /// Without a terminal signal, an agent counts as running only if it was updated this recently.
    public static let staleAfter: TimeInterval = 300

    public static func isRecent(_ updatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) < staleAfter
    }

    public static func statusWithoutTerminalSignal(updatedAt: Date, now: Date) -> AgentStatus {
        isRecent(updatedAt, now: now) ? .running : .unknown
    }
}
