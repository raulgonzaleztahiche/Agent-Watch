import Adapters
import AgentCore
import Foundation
import Observation

/// Polls the repository off the main thread and publishes the result to SwiftUI.
@MainActor
@Observable
final class AgentStore {
    private(set) var rows: [AgentRow] = []
    private(set) var summary = AgentSummary([])
    private(set) var errors: [String] = []

    private let repository: AgentRepository
    private let window: TimeInterval
    private let interval: Duration
    private var pollTask: Task<Void, Never>?

    init(window: TimeInterval = 24 * 3600, interval: Duration = .seconds(2)) {
        repository = AgentRepository { [ClaudeCodeSource(), OpenCodeSource()] }
        self.window = window
        self.interval = interval
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refresh() async {
        let result = await repository.fetch(window: window)
        rows = AgentTree.rows(result.agents)
        summary = AgentSummary(result.agents)
        errors = result.errors
    }
}
