import Foundation
import Observation
import ServiceManagement

/// Wraps `SMAppService.mainApp`. It only works from a real `.app` bundle,
/// so it reports itself unavailable when run through `swift run`.
@MainActor
@Observable
final class LaunchAtLogin {
    let isAvailable: Bool
    private(set) var isEnabled = false
    private(set) var errorMessage: String?

    init() {
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
        refresh()
    }

    func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        isEnabled = isAvailable && SMAppService.mainApp.status == .enabled
    }
}
