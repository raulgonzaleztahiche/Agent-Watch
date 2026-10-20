import AgentCore
import Foundation
import Testing

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Tuesday 2026-10-20 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_508_400)
private let startOfToday = calendar.startOfDay(for: now)

private func entry(
    _ model: String? = "gpt-6-luna", provider: String? = "openai", variant: String? = "high",
    tool: AgentTool = .openCode, hoursAgo: Double = 1, input: Int = 100, output: Int = 10,
    cacheRead: Int = 0, cost: Double? = nil
) -> UsageEntry {
    UsageEntry(
        tool: tool, model: model.map { ModelRef(provider: provider, id: $0, variant: variant) },
        date: now.addingTimeInterval(-hoursAgo * 3600),
        usage: TokenUsage(input: input, output: output, cacheRead: cacheRead), cost: cost)
}

@Suite struct UsageReportTests {
    @Test func groupsByToolAndModelIgnoringTheVariant() {
        let report = UsageReport.make(entries: [
            entry(variant: "high", input: 100, output: 10),
            entry(variant: "xhigh", input: 200, output: 20),
            entry(variant: nil, input: 300, output: 30),
        ], now: now, calendar: calendar)

        #expect(report.today.models.count == 1)
        #expect(report.today.models[0].model == "openai/gpt-6-luna")
        #expect(report.today.models[0].usage == TokenUsage(input: 600, output: 60))
        #expect(report.today.models[0].messages == 3)
    }

    @Test func theSameModelNameInTwoToolsStaysSeparate() {
        let report = UsageReport.make(entries: [
            entry("claude-sonnet-5-5", provider: "anthropic", tool: .claudeCode),
            entry("claude-sonnet-5-5", provider: "anthropic", tool: .openCode),
        ], now: now, calendar: calendar)

        #expect(Set(report.today.models.map(\.id)) == [
            "claude-code|anthropic/claude-sonnet-5-5", "opencode|anthropic/claude-sonnet-5-5",
        ])
    }

    @Test func ordersModelsByFreshTokensIgnoringCacheReads() {
        let report = UsageReport.make(entries: [
            entry("small", input: 10, output: 10, cacheRead: 9_000_000),
            entry("big", input: 5_000, output: 500),
        ], now: now, calendar: calendar)

        #expect(report.today.models.map(\.model) == ["openai/big", "openai/small"])
    }

    @Test func todayStartsAtLocalMidnightAndWeekCoversSevenCalendarDays() {
        let report = UsageReport.make(entries: [
            UsageEntry(tool: .openCode, model: nil, date: startOfToday, usage: TokenUsage(input: 1)),
            UsageEntry(tool: .openCode, model: nil, date: startOfToday.addingTimeInterval(-1), usage: TokenUsage(input: 10)),
            UsageEntry(tool: .openCode, model: nil, date: UsageReport.windowStart(now: now, calendar: calendar), usage: TokenUsage(input: 100)),
            UsageEntry(tool: .openCode, model: nil, date: UsageReport.windowStart(now: now, calendar: calendar).addingTimeInterval(-1), usage: TokenUsage(input: 1000)),
        ], now: now, calendar: calendar)

        #expect(report.today.total.input == 1)
        #expect(report.week.total.input == 111)
        #expect(UsageReport.windowStart(now: now, calendar: calendar)
            == calendar.date(byAdding: .day, value: -6, to: startOfToday))
    }

    @Test func ignoresEntriesFromTheFuture() {
        let future = UsageEntry(
            tool: .openCode, model: nil, date: now.addingTimeInterval(3600), usage: TokenUsage(input: 5))

        #expect(UsageReport.make(entries: [future], now: now, calendar: calendar) == .empty)
    }

    @Test func entriesWithoutAModelAreGroupedAsUnknown() {
        let report = UsageReport.make(entries: [entry(nil), entry(nil)], now: now, calendar: calendar)

        #expect(report.today.models.map(\.model) == ["unknown model"])
        #expect(report.today.messages == 2)
    }

    @Test func costIsNilUntilSomethingIsPricedAndNeverShowsZero() {
        let unpriced = UsageReport.make(entries: [entry(cost: 0), entry(cost: nil)], now: now, calendar: calendar)
        let priced = UsageReport.make(entries: [entry(cost: 0.25), entry(cost: 0.5), entry(cost: 0)], now: now, calendar: calendar)

        #expect(unpriced.today.cost == nil)
        #expect(unpriced.today.models[0].cost == nil)
        #expect(priced.today.cost == 0.75)
    }

    @Test func totalAddsEveryModel() {
        let report = UsageReport.make(entries: [
            entry("a", input: 1, output: 2, cacheRead: 3), entry("b", input: 10, output: 20, cacheRead: 30),
        ], now: now, calendar: calendar)

        #expect(report.today.total == TokenUsage(input: 11, output: 22, cacheRead: 33))
    }

    @Test func noEntriesGivesAnEmptyReport() {
        let report = UsageReport.make(entries: [], now: now, calendar: calendar)

        #expect(report == .empty)
        #expect(report.today.isEmpty)
    }
}
