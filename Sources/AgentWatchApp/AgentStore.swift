import Adapters
import AgentCore
import Foundation
import Observation

/// Polls the repository off the main thread and publishes the result to SwiftUI.
enum PanelTab: String, CaseIterable {
    case agents = "Agents"
    case usage = "Usage"
}

@MainActor
@Observable
final class AgentStore {
    var tab = PanelTab.agents {
        didSet { if tab != oldValue { refreshLimitsIfNeeded() } }
    }
    private(set) var usageReport = UsageReport.empty
    /// Plan limits as reported by the providers. Only fetched while the Usage tab is on screen.
    private(set) var limits: [PlanLimit] = []
    private(set) var limitsError: String?
    /// Set by the popover; limits are never fetched while nobody is looking.
    var isPanelVisible = false {
        didSet { if isPanelVisible && !oldValue { refreshLimitsIfNeeded() } }
    }

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

    /// Whether the "Recent" section is unfolded; remembered between launches.
    var showRecent: Bool {
        didSet { UserDefaults.standard.set(showRecent, forKey: Self.showRecentKey) }
    }

    private let limitRepository = LimitRepository { [CodexLimitSource()] }
    private var limitsInFlight = false
    private var lastLimitsRefresh = Date.distantPast

    private let repository: AgentRepository
    private let window: TimeInterval
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var lastUsageRefresh = Date.distantPast
    private var usageErrors: [String] = []
    private var detector = TransitionDetector()
    private let notifier = Notifier()

    /// Usage covers a week of messages and changes slowly, so it is refreshed less often than agents.
    private static let usageRefreshInterval: TimeInterval = 15
    /// Fetching limits starts a process, so it is done at most this often.
    private static let limitsRefreshInterval: TimeInterval = 60

    private static let notifyOnFinishKey = "notifyOnFinish"
    private static let showRecentKey = "showRecent"

    init(window: TimeInterval = 24 * 3600, interval: Duration = .seconds(2)) {
        repository = AgentRepository { [ClaudeCodeSource(), OpenCodeSource()] }
        self.window = window
        self.interval = interval
        notifyOnFinish = UserDefaults.standard.bool(forKey: Self.notifyOnFinishKey)
        showRecent = UserDefaults.standard.bool(forKey: Self.showRecentKey)
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
        var allErrors = result.errors
        for event in detector.observe(result.agents) where event.isAlert || notifyOnFinish {
            notifier.post(event)
        }

        if polledAt.timeIntervalSince(lastUsageRefresh) >= Self.usageRefreshInterval {
            lastUsageRefresh = polledAt
            let usage = await repository.fetchUsage(since: UsageReport.windowStart(now: polledAt))
            usageReport = UsageReport.make(entries: usage.entries, now: polledAt)
            usageErrors = usage.errors
        }
        allErrors += usageErrors.filter { !allErrors.contains($0) }
        errors = allErrors
        refreshLimitsIfNeeded()
    }

    /// Starts a background fetch when the Usage tab is visible and the last one is old enough.
    /// It never blocks the polling loop: the provider process can take a second or more.
    private func refreshLimitsIfNeeded() {
        guard isPanelVisible, tab == .usage, !limitsInFlight,
              Date().timeIntervalSince(lastLimitsRefresh) >= Self.limitsRefreshInterval
        else { return }
        limitsInFlight = true
        Task {
            let result = await limitRepository.fetch()
            limits = result.limits
            limitsError = result.errors.first
            lastLimitsRefresh = Date()
            limitsInFlight = false
        }
    }
}
