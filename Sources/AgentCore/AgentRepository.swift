import Foundation

public struct FetchResult: Sendable, Equatable {
    public let agents: [Agent]
    /// One message per source that failed. A failing source never hides the others.
    public let errors: [String]

    public init(agents: [Agent], errors: [String]) {
        self.agents = agents
        self.errors = errors
    }
}

public struct UsageFetchResult: Sendable, Equatable {
    public let entries: [UsageEntry]
    public let errors: [String]

    public init(entries: [UsageEntry], errors: [String]) {
        self.entries = entries
        self.errors = errors
    }
}

/// Owns the sources (which keep non-thread-safe caches) and serializes access to them,
/// so polling can run off the main thread.
public actor AgentRepository {
    private let sources: [any AgentSource]

    public init(makeSources: @Sendable () -> [any AgentSource]) {
        sources = makeSources()
    }

    public func fetch(window: TimeInterval, now: Date = Date()) -> FetchResult {
        let since = now.addingTimeInterval(-window)
        var agents: [Agent] = []
        var errors: [String] = []
        for source in sources {
            do {
                agents += try source.fetchAgents(updatedSince: since, now: now)
            } catch {
                errors.append("\(source.tool.rawValue): \(error)")
            }
        }
        return FetchResult(agents: agents, errors: errors)
    }

    /// Per-message usage from every source that reports it. A failing source never hides the others.
    public func fetchUsage(since: Date) -> UsageFetchResult {
        var entries: [UsageEntry] = []
        var errors: [String] = []
        for source in sources {
            guard let usageSource = source as? any UsageSource else { continue }
            do {
                entries += try usageSource.fetchUsage(since: since)
            } catch {
                errors.append("\(source.tool.rawValue): \(error)")
            }
        }
        return UsageFetchResult(entries: entries, errors: errors)
    }
}
