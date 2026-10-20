import Foundation

/// The short time text shown at the right of each row.
///
/// - running subagent: how long it has been running ("running 1m 20s")
/// - finished subagent: how long it took ("took 2m 5s", "failed after 2m", "stopped after 2m")
/// - everything else (sessions, stale subagents): when it last did something ("3m ago")
public enum ActivityLabel {
    public static func text(for agent: Agent, now: Date) -> String {
        if !agent.isMainSession {
            let elapsed = agent.updatedAt.timeIntervalSince(agent.startedAt)
            switch agent.status {
            case .running: return "running \(duration(now.timeIntervalSince(agent.startedAt)))"
            case .succeeded: return "took \(duration(elapsed))"
            case .failed: return "failed after \(duration(elapsed))"
            case .interrupted: return "stopped after \(duration(elapsed))"
            case .idle, .unknown: break
            }
        }
        return ago(now.timeIntervalSince(agent.updatedAt))
    }

    /// 45 -> "45s", 125 -> "2m 5s", 120 -> "2m", 4320 -> "1h 12m", 90_000 -> "1d 1h"
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (days, hours, minutes, secs) = (total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60, total % 60)
        if days > 0 { return join(days, "d", hours, "h") }
        if hours > 0 { return join(hours, "h", minutes, "m") }
        if minutes > 0 { return join(minutes, "m", secs, "s") }
        return "\(secs)s"
    }

    /// Under 10 s -> "just now", otherwise one unit: "45s ago", "12m ago", "3h ago", "2d ago".
    public static func ago(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        switch total {
        case ..<10: return "just now"
        case ..<60: return "\(total)s ago"
        case ..<3_600: return "\(total / 60)m ago"
        case ..<86_400: return "\(total / 3_600)h ago"
        default: return "\(total / 86_400)d ago"
        }
    }

    private static func join(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
        minor == 0 ? "\(major)\(majorUnit)" : "\(major)\(majorUnit) \(minor)\(minorUnit)"
    }
}
