import Foundation

/// Port: anything that can report the sessions and subagents of one tool.
public protocol AgentSource {
    var tool: AgentTool { get }
    /// Returns every main session and subagent updated at or after `updatedSince`.
    func fetchAgents(updatedSince: Date, now: Date) throws -> [Agent]
}

public enum AgentSourceError: Error, CustomStringConvertible {
    case dataNotFound(String)
    case readFailed(String)

    public var description: String {
        switch self {
        case .dataNotFound(let detail): "Data not found: \(detail)"
        case .readFailed(let detail): "Read failed: \(detail)"
        }
    }
}
