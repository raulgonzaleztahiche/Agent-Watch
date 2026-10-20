import AgentCore
import AppKit
import SwiftUI

/// Menu bar item plus popover. Used instead of `MenuBarExtra(.window)`, whose window does not
/// shrink when the content gets shorter and leaves a see-through empty panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: AgentStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(store: AgentStore, launchAtLogin: LaunchAtLogin) {
        self.store = store
        super.init()

        let hosting = NSHostingController(rootView: AgentListView(store: store, launchAtLogin: launchAtLogin))
        // The popover follows the content's size as rows appear, disappear or fold.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeft
        }
        update(for: store.summary)
        store.onSummaryChange = { [weak self] summary in self?.update(for: summary) }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // An accessory app is not active by default; without this the first click is swallowed.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func update(for summary: AgentSummary) {
        guard let button = statusItem.button else { return }
        let running = summary.totalRunning
        button.image = running > 0 ? MenuBarGlyph.active : MenuBarGlyph.idle
        button.title = running > 0 ? " \(running)" : ""
    }
}

extension StatusItemController {
    func popoverWillShow(_ notification: Notification) { store.isPanelVisible = true }
    func popoverDidClose(_ notification: Notification) { store.isPanelVisible = false }
}
