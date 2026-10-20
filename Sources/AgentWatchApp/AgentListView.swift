import AgentCore
import AppKit
import SwiftUI

struct AgentListView: View {
    let store: AgentStore
    let launchAtLogin: LaunchAtLogin

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
            Text("\(summary.runningSessions) sessions · \(summary.runningSubagents) subagents running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty {
            Text("No activity in the last 24 hours")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.rows) { row in
                        AgentRowView(row: row)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)
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
            Text(agent.startedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 12 + CGFloat(row.depth) * 18)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
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
