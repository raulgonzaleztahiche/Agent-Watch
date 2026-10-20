import Foundation

public enum ResumeCommand {
    /// A shell command that reopens a main session in its project folder, or `nil` for subagents
    /// (they cannot be resumed on their own).
    ///
    /// - Claude Code: `claude --resume <id>`
    /// - OpenCode: `opencode --session <id>`
    public static func make(for agent: Agent) -> String? {
        guard agent.isMainSession else { return nil }
        let command = switch agent.tool {
        case .claudeCode: "claude --resume \(shellQuoted(agent.id))"
        case .openCode: "opencode --session \(shellQuoted(agent.id))"
        }
        guard let directory = agent.directory, !directory.isEmpty else { return command }
        return "cd \(shellQuoted(directory)) && \(command)"
    }

    /// Single-quotes a value for a POSIX shell: `it's` -> `'it'\''s'`.
    public static func shellQuoted(_ value: String) -> String {
        let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@".contains($0) }
        guard !safe, !value.isEmpty else { return value.isEmpty ? "''" : value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
