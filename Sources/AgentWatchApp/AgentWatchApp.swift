import AppKit

@main
enum AgentWatchMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // Menu bar only: no Dock icon, no app menu (also set by LSUIElement in the bundle).
        app.setActivationPolicy(.accessory)

        let store = AgentStore()
        let controller = StatusItemController(store: store, launchAtLogin: LaunchAtLogin())
        store.start()

        withExtendedLifetime(controller) { app.run() }
    }
}
