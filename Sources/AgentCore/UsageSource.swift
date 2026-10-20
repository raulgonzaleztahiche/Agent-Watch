import Foundation

/// Tokens of one model response, with when and by which model it happened.
public struct UsageEntry: Sendable, Equatable {
    public let tool: AgentTool
    public let model: ModelRef?
    public let date: Date
    public let usage: TokenUsage
    /// Cost in USD when the tool reports one (never estimated).
    public let cost: Double?

    public init(tool: AgentTool, model: ModelRef?, date: Date, usage: TokenUsage, cost: Double? = nil) {
        self.tool = tool
        self.model = model
        self.date = date
        self.usage = usage
        self.cost = cost
    }
}

/// Port: a tool that can report its per-message usage.
public protocol UsageSource {
    var tool: AgentTool { get }
    /// Every model response at or after `since`.
    func fetchUsage(since: Date) throws -> [UsageEntry]
}
