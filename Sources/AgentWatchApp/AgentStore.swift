import Adapters
import AgentCore
import Foundation
import Observation

/// Polls the repository off the main thread and publishes the result to SwiftUI.
@MainActor
@Observable
final class AgentStore {
    private(set) var sections = AgentSections.empty
    /// Time of the last poll, so rows can show elapsed time without their own timers.
    private(set) var now = Date()
    private(set) var summary = AgentSummary([])
    /// Called on the main actor whenever the running counts change.
    @ObservationIgnored var onSummaryChange: ((AgentSummary) -> Void)?
    private(set) var errors: [String] = []
    /// Failures and interruptions always notify; a clean finish only when this is on.
    var notifyOnFinish: Bool {
        didSet { UserDefaults.standard.set(notifyOnFinish, forKey: Self.notifyOnFinishKey) }
    }

    private let repository: AgentRepository
    private let window: TimeInterval
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var detector = TransitionDetector()
    private let notifier = Notifier()

    private static let notifyOnFinishKey = "notifyOnFinish"

    init(window: TimeInterval = 24 * 3600, interval: Duration = .seconds(2)) {
        repository = AgentRepository { [ClaudeCodeSource(), OpenCodeSource()] }
        self.window = window
        self.interval = interval
        notifyOnFinish = UserDefaults.standard.bool(forKey: Self.notifyOnFinishKey)
    }

    func start() {
        guard pollTask == nil else { return }
        notifier.requestAuthorization()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refresh() async {
        let polledAt = Date()
        let result = await repository.fetch(window: window, now: polledAt)
        now = polledAt
        sections = AgentTree.sections(result.agents, now: polledAt)
        let newSummary = AgentSummary(result.agents)
        if newSummary != summary {
            summary = newSummary
            onSummaryChange?(newSummary)
        }
        errors = result.errors
        for event in detector.observe(result.agents) where event.isAlert || notifyOnFinish {
            notifier.post(event)
        }
    }
}
