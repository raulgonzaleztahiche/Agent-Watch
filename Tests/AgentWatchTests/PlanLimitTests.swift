import AgentCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)

@Suite struct LimitWindowTests {
    @Test(arguments: [
        (10_080, "Weekly"), (1_440, "Daily"), (300, "5 hours"), (60, "1 hour"), (4_320, "3 days"),
        (45, "45 min"), (90, "90 min"),
    ])
    func labelsKnownWindowLengths(minutes: Int, expected: String) {
        #expect(LimitWindow.label(forMinutes: minutes) == expected)
    }

    @Test func unknownLengthIsJustALimit() {
        #expect(LimitWindow.label(forMinutes: nil) == "Limit")
        #expect(LimitWindow.label(forMinutes: 0) == "Limit")
    }

    @Test(arguments: [
        (0, LimitWindow.Severity.normal), (79, .normal), (80, .warning), (94, .warning), (95, .critical), (100, .critical),
    ])
    func severityFollowsTheUsedPercentage(percent: Int, expected: LimitWindow.Severity) {
        #expect(LimitWindow(minutes: 10_080, usedPercent: percent, resetsAt: nil).severity == expected)
    }

    @Test func resetsInShowsTheTimeLeft() {
        let window = LimitWindow(minutes: 10_080, usedPercent: 2, resetsAt: now.addingTimeInterval(6 * 86_400 + 22 * 3_600))

        #expect(window.resetsIn(now: now) == "6d 22h")
    }

    @Test func resetsInIsNowOncePassedAndNilWhenUnknown() {
        #expect(LimitWindow(minutes: 300, usedPercent: 1, resetsAt: now.addingTimeInterval(-5)).resetsIn(now: now) == "now")
        #expect(LimitWindow(minutes: 300, usedPercent: 1, resetsAt: nil).resetsIn(now: now) == nil)
    }
}

@Suite struct PlanLimitTests {
    @Test func titleOmitsTheNameWhenItRepeatsTheProvider() {
        #expect(PlanLimit(provider: "Codex", name: "codex", plan: "team", windows: []).title == "Codex")
        #expect(PlanLimit(provider: "Codex", name: "spark", plan: nil, windows: []).title == "Codex · spark")
    }
}

private struct FakeLimitSource: LimitSource {
    let provider: String
    let result: Result<[PlanLimit], AgentSourceError>
    func fetchLimits() throws -> [PlanLimit] { try result.get() }
}

@Suite struct LimitRepositoryTests {
    private let weekly = PlanLimit(
        provider: "Codex", name: "codex", plan: "team",
        windows: [LimitWindow(minutes: 10_080, usedPercent: 2, resetsAt: nil)])

    @Test func mergesTheLimitsOfEverySource() async {
        let other = PlanLimit(provider: "Other", name: "other", plan: nil, windows: [])
        let repository = LimitRepository {
            [FakeLimitSource(provider: "Codex", result: .success([weekly])),
             FakeLimitSource(provider: "Other", result: .success([other]))]
        }

        let result = await repository.fetch()

        #expect(result.limits == [weekly, other])
        #expect(result.errors.isEmpty)
    }

    @Test func aMissingToolIsSilentNotAnError() async {
        let repository = LimitRepository {
            [FakeLimitSource(provider: "Codex", result: .failure(.dataNotFound("codex")))]
        }

        #expect(await repository.fetch() == LimitFetchResult(limits: [], errors: []))
    }

    @Test func aFailingSourceIsReportedAndDoesNotHideTheOthers() async {
        let repository = LimitRepository {
            [FakeLimitSource(provider: "Codex", result: .failure(.readFailed("timed out"))),
             FakeLimitSource(provider: "Other", result: .success([weekly]))]
        }

        let result = await repository.fetch()

        #expect(result.limits == [weekly])
        #expect(result.errors.count == 1 && result.errors[0].hasPrefix("Codex:"))
    }
}
