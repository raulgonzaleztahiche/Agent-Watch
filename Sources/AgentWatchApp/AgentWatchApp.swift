import AppKit
import SwiftUI

@main
struct AgentWatchApp: App {
    private let store: AgentStore
    private let launchAtLogin = LaunchAtLogin()

    init() {
        // Menu bar only: no Dock icon, no app menu (also set by LSUIElement in the bundle).
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = AgentStore()
        store.start()
        self.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            AgentListView(store: store, launchAtLogin: launchAtLogin)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let store: AgentStore

    var body: some View {
        let running = store.summary.totalRunning
        HStack(spacing: 4) {
            Image(systemName: running > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
            if running > 0 {
                Text("\(running)")
            }
        }
    }
}
