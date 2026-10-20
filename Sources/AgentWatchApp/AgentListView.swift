import AgentCore
import AppKit
import SwiftUI

struct AgentListView: View {
    let store: AgentStore
    let launchAtLogin: LaunchAtLogin
    @State private var showRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480)
    }

    private var header: some View {
        let summary = store.summary
        return HStack {
            Text("Agent Watch").font(.headline)
            Spacer()
            Text(summary.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if store.sections.active.isEmpty && store.sections.recent.isEmpty {
            Text("No activity in the last 24 hours")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            AgentRowsList(sections: store.sections, showRecent: $showRecent)
        }
    }

    private var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!launchAtLogin.isAvailable)
                .help(launchAtLogin.isAvailable ? "" : "Only available from the packaged .app")
                Toggle("Also notify when a subagent finishes", isOn: Binding(
                    get: { store.notifyOnFinish },
                    set: { store.notifyOnFinish = $0 }
                ))
                .toggleStyle(.checkbox)
                .help("Failures and interruptions always notify")
                ForEach(store.errors + [launchAtLogin.errorMessage].compactMap { $0 }, id: \.self) { error in
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(10)
    }
}

/// Running agents first and highlighted; everything else folded under "Recent".
///
/// A `ScrollView` inside a window-style `MenuBarExtra` has no ideal height and collapses to
/// zero, so the height is computed from the items (each kind has a fixed height).
struct AgentRowsList: View {
    nonisolated static let rowHeight: CGFloat = 44
    nonisolated static let headerHeight: CGFloat = 30
    nonisolated static let verticalPadding: CGFloat = 4
    nonisolated static let maxHeight: CGFloat = 420

    let sections: AgentSections
    @Binding var showRecent: Bool

    private enum Item: Identifiable {
        case runningHeader
        case nothingRunning
        case row(AgentRow)
        case recentHeader

        var id: String {
            switch self {
            case .runningHeader: "running-header"
            case .nothingRunning: "nothing-running"
            case .row(let row): row.id
            case .recentHeader: "recent-header"
            }
        }

        var height: CGFloat {
            switch self {
            case .runningHeader, .recentHeader: AgentRowsList.headerHeight
            case .nothingRunning, .row: AgentRowsList.rowHeight
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = [.runningHeader]
        items += sections.active.isEmpty ? [.nothingRunning] : sections.active.map(Item.row)
        if sections.recentTreeCount > 0 {
            items.append(.recentHeader)
            if showRecent { items += sections.recent.map(Item.row) }
        }
        return items
    }

    var body: some View {
        let items = items
        let height = min(items.reduce(2 * Self.verticalPadding) { $0 + $1.height }, Self.maxHeight)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    view(for: item)
                }
            }
            .padding(.vertical, Self.verticalPadding)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func view(for item: Item) -> some View {
        switch item {
        case .runningHeader:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("RUNNING NOW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: Self.headerHeight)
        case .nothingRunning:
            Text("Nothing running right now")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: Self.rowHeight, alignment: .leading)
        case .row(let row):
            AgentRowView(row: row)
        case .recentHeader:
            Button {
                showRecent.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showRecent ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("RECENT · \(sections.recentTreeCount)").font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        let agent = row.agent
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(agent.status.color)
                .frame(width: 8, height: 8)
                .help(agent.status.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name).fontWeight(agent.isMainSession ? .semibold : .regular)
                    Text(agent.model?.displayName ?? "unknown model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let title = TitleFormatter.clean(agent.title, maxLength: 60)
                if !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(agent.startedAt, style: .relative)
                if let usage = agent.usage {
                    Text(usageLine(usage, cost: agent.cost)).help(usage.detail)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.leading, 12 + CGFloat(row.depth) * 18)
        .padding(.trailing, 12)
        .frame(height: AgentRowsList.rowHeight, alignment: .leading)
        .background(agent.status == .running ? Color.green.opacity(0.14) : Color.clear)
    }
}

private func usageLine(_ usage: TokenUsage, cost: Double?) -> String {
    guard let cost else { return usage.summary }
    return usage.summary + " · " + String(format: "$%.2f", cost)
}

private extension AgentStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .idle, .unknown: .gray
        case .succeeded: .blue
        case .failed: .red
        case .interrupted: .orange
        }
    }
}
