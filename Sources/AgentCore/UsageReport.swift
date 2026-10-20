import Foundation

public struct ModelUsage: Sendable, Equatable, Identifiable {
    public let tool: AgentTool
    /// Provider and model without the variant, e.g. "openai/gpt-6-luna".
    public let model: String
    public let usage: TokenUsage
    public let messages: Int
    public let cost: Double?

    public var id: String { "\(tool.rawValue)|\(model)" }

    /// Input plus output. Cache reads are left out: they dwarf everything else and are cheap.
    public var freshTokens: Int { usage.input + usage.output }
}

public struct UsagePeriod: Sendable, Equatable {
    /// Most used first.
    public let models: [ModelUsage]
    public let total: TokenUsage
    public let messages: Int
    public let cost: Double?

    public static let empty = UsagePeriod(models: [], total: TokenUsage(), messages: 0, cost: nil)

    public var isEmpty: Bool { messages == 0 }
}

public struct UsageReport: Sendable, Equatable {
    public let today: UsagePeriod
    /// The last seven calendar days, today included.
    public let week: UsagePeriod

    public static let empty = UsageReport(today: .empty, week: .empty)

    /// The oldest instant the report needs, so sources can skip anything older.
    public static func windowStart(now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
    }

    public static func make(entries: [UsageEntry], now: Date, calendar: Calendar = .current) -> UsageReport {
        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = windowStart(now: now, calendar: calendar)
        let inWeek = entries.filter { $0.date >= weekStart && $0.date <= now }
        return UsageReport(
            today: period(inWeek.filter { $0.date >= startOfToday }),
            week: period(inWeek)
        )
    }

    private static func period(_ entries: [UsageEntry]) -> UsagePeriod {
        let groups = Dictionary(grouping: entries) { "\($0.tool.rawValue)|\($0.model?.name ?? "unknown model")" }
        let models = groups.values.map { group -> ModelUsage in
            ModelUsage(
                tool: group[0].tool,
                model: group[0].model?.name ?? "unknown model",
                usage: group.map(\.usage).reduce(TokenUsage(), +),
                messages: group.count,
                cost: sum(group.compactMap(\.cost))
            )
        }.sorted { ($0.freshTokens, $1.model) > ($1.freshTokens, $0.model) }

        return UsagePeriod(
            models: models,
            total: models.map(\.usage).reduce(TokenUsage(), +),
            messages: entries.count,
            cost: sum(entries.compactMap(\.cost))
        )
    }

    /// `nil` when nothing was priced, so "no price" is never shown as "$0.00".
    private static func sum(_ costs: [Double]) -> Double? {
        let positive = costs.filter { $0 > 0 }
        return positive.isEmpty ? nil : positive.reduce(0, +)
    }
}
