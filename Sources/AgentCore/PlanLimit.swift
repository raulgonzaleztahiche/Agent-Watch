import Foundation

/// One usage window of a plan, e.g. "weekly: 2 % used, resets in 6d 22h".
public struct LimitWindow: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    public let minutes: Int?
    public let usedPercent: Int
    public let resetsAt: Date?

    public init(minutes: Int?, usedPercent: Int, resetsAt: Date?) {
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// 80 % and above warns, 95 % and above is critical.
    public var severity: Severity {
        usedPercent >= 95 ? .critical : usedPercent >= 80 ? .warning : .normal
    }

    public var label: String { Self.label(forMinutes: minutes) }

    /// 10080 -> "Weekly", 1440 -> "Daily", 300 -> "5 hours", 45 -> "45 min", nil -> "Limit"
    public static func label(forMinutes minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Limit" }
        switch minutes {
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        case 60: return "1 hour"
        case let m where m % 1_440 == 0: return "\(m / 1_440) days"
        case let m where m % 60 == 0: return "\(m / 60) hours"
        default: return "\(minutes) min"
        }
    }

    /// "6d 22h", or "now" once the reset time has passed. `nil` when the reset time is unknown.
    public func resetsIn(now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        return seconds <= 0 ? "now" : ActivityLabel.duration(seconds)
    }
}

/// A plan's limits as reported by the provider (not computed from local data).
public struct PlanLimit: Sendable, Equatable, Identifiable {
    public let provider: String
    /// Limit id from the provider, e.g. "codex".
    public let name: String
    public let plan: String?
    public let windows: [LimitWindow]

    public var id: String { "\(provider)|\(name)" }

    /// "Codex", or "Codex · spark" when the provider reports several limits.
    public var title: String {
        name.lowercased() == provider.lowercased() ? provider : "\(provider) · \(name)"
    }

    public init(provider: String, name: String, plan: String?, windows: [LimitWindow]) {
        self.provider = provider
        self.name = name
        self.plan = plan
        self.windows = windows
    }
}

/// Port: a provider that can report plan limits.
public protocol LimitSource {
    var provider: String { get }
    /// Throws `AgentSourceError.dataNotFound` when the provider's tool is not installed.
    func fetchLimits() throws -> [PlanLimit]
}

public struct LimitFetchResult: Sendable, Equatable {
    public let limits: [PlanLimit]
    /// Sources that exist but failed. Missing tools are not errors: they are simply absent.
    public let errors: [String]

    public init(limits: [PlanLimit], errors: [String]) {
        self.limits = limits
        self.errors = errors
    }
}

/// Serializes access to the limit sources, which can spawn a process and block for a while.
/// Kept apart from `AgentRepository` so a slow provider never delays the agent polling.
public actor LimitRepository {
    private let sources: [any LimitSource]

    public init(makeSources: @Sendable () -> [any LimitSource]) {
        sources = makeSources()
    }

    public func fetch() -> LimitFetchResult {
        var limits: [PlanLimit] = []
        var errors: [String] = []
        for source in sources {
            do {
                limits += try source.fetchLimits()
            } catch AgentSourceError.dataNotFound {
                continue
            } catch {
                errors.append("\(source.provider): \(error)")
            }
        }
        return LimitFetchResult(limits: limits, errors: errors)
    }
}
