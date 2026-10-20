import Foundation

public struct FetchResult: Sendable, Equatable {
    public let agents: [Agent]
    /// One message per source that failed. A failing source never hides the others.
    public let errors: [String]
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
}
