import AgentCore
import SwiftUI

/// Token usage per model for today or the last seven days.
///
/// Like the agent list, the scrolling area gets an explicit height: a `ScrollView` inside the
/// popover has no ideal height of its own.
struct UsageView: View {
    nonisolated static let totalHeight: CGFloat = 40
    nonisolated static let rowHeight: CGFloat = 52
    nonisolated static let emptyHeight: CGFloat = 90
    nonisolated static let maxListHeight: CGFloat = 400
    nonisolated static let limitsHeaderHeight: CGFloat = 30
    nonisolated static let limitTitleHeight: CGFloat = 24
    nonisolated static let limitWindowHeight: CGFloat = 36
    nonisolated static let limitsNoteHeight: CGFloat = 22

    let report: UsageReport
    let limits: [PlanLimit]
    let limitsError: String?
    let now: Date
    @State private var period = Period.today

    enum Period: String, CaseIterable {
        case today = "Today"
        case week = "7 days"
    }

    private var current: UsagePeriod { period == .today ? report.today : report.week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content(for: current)
        }
    }

    private var limitsHeight: CGFloat {
        guard !limits.isEmpty || limitsError != nil else { return 0 }
        let plans = limits.reduce(CGFloat(0)) { $0 + Self.limitTitleHeight + CGFloat($1.windows.count) * Self.limitWindowHeight }
        return Self.limitsHeaderHeight + plans + (limits.isEmpty ? Self.limitsNoteHeight : 0)
    }

    private func content(for period: UsagePeriod) -> some View {
        let maxFresh = max(period.models.map(\.freshTokens).max() ?? 1, 1)
        let usageHeight = period.isEmpty
            ? Self.emptyHeight : Self.totalHeight + CGFloat(period.models.count) * Self.rowHeight
        let height = min(limitsHeight + usageHeight + 8, Self.maxListHeight)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                limitsSection
                if period.isEmpty {
                    Text("No usage in this period")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.emptyHeight)
                } else {
                    totalRow(period)
                    ForEach(period.models) { model in
                        ModelUsageRow(model: model, share: Double(model.freshTokens) / Double(maxFresh))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var limitsSection: some View {
        if !limits.isEmpty || limitsError != nil {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.caption2)
                Text("PLAN LIMITS").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Self.limitsHeaderHeight)
            ForEach(limits) { limit in
                LimitRow(limit: limit, now: now)
            }
            if limits.isEmpty, let limitsError {
                Text("Limits unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: Self.limitsNoteHeight, alignment: .leading)
                    .help(limitsError)
            }
            Divider().padding(.vertical, 4)
        }
    }

    private func totalRow(_ period: UsagePeriod) -> some View {
        HStack {
            Text("TOTAL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(detail(period.total, messages: period.messages, cost: period.cost))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.totalHeight - 8)
        .padding(.bottom, 8)
    }
}

private struct LimitRow: View {
    let limit: PlanLimit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(limit.title).fontWeight(.semibold)
                if let plan = limit.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: UsageView.limitTitleHeight, alignment: .leading)
            ForEach(Array(limit.windows.enumerated()), id: \.offset) { _, window in
                LimitWindowRow(window: window, now: now)
            }
        }
    }
}

private struct LimitWindowRow: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.caption)
                Spacer()
                Text("\(window.usedPercent)% used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(window.severity.color)
                if let reset = window.resetsIn(now: now) {
                    Text("· resets in \(reset)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(window.severity.color)
                            .frame(width: max(proxy.size.width * Double(min(window.usedPercent, 100)) / 100, 3))
                    }
                }
        }
        .padding(.horizontal, 12)
        .frame(height: UsageView.limitWindowHeight, alignment: .leading)
    }
}

private extension LimitWindow.Severity {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct ModelUsageRow: View {
    let model: ModelUsage
    /// 0...1, relative to the busiest model of the period.
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.model).fontWeight(.semibold).lineLimit(1)
                Text(model.tool.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("in \(TokenUsage.compact(model.usage.input)) · out \(TokenUsage.compact(model.usage.output))")
                    .font(.caption)
            }
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(model.tool.tint).frame(width: max(proxy.size.width * share, 3))
                    }
                }
            Text(detail(model.usage, messages: model.messages, cost: model.cost, includeFresh: false))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: UsageView.rowHeight, alignment: .leading)
        .help(model.usage.detail)
    }
}

/// "in 1.1M · out 260.3k · cache 59.9M · 422 msgs · $1.20"
private func detail(_ usage: TokenUsage, messages: Int, cost: Double?, includeFresh: Bool = true) -> String {
    var parts: [String] = []
    if includeFresh {
        parts.append("in \(TokenUsage.compact(usage.input))")
        parts.append("out \(TokenUsage.compact(usage.output))")
    }
    parts.append("cache \(TokenUsage.compact(usage.cacheRead))")
    parts.append("\(messages) msg\(messages == 1 ? "" : "s")")
    if let cost { parts.append(String(format: "$%.2f", cost)) }
    return parts.joined(separator: " · ")
}

private extension AgentTool {
    var tint: Color {
        switch self {
        case .claudeCode: .orange
        case .openCode: .blue
        }
    }
}
