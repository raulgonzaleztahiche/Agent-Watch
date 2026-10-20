import AgentCore
import Foundation
import UserNotifications

/// Posts system notifications. Like `LaunchAtLogin`, it only works from a real `.app`
/// bundle; from `swift run` it does nothing instead of crashing.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    override init() {
        super.init()
        if isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func post(_ event: AgentEvent) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        if event.isAlert { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Without this, macOS hides notifications while the menu popover (this app) is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
