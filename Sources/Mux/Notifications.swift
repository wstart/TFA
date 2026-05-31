import Foundation
import UserNotifications

/// Local system notifications (macOS Notification Center) for background-terminal output completion.
///
/// No-ops when the executable has no bundle identifier (e.g. `swift run Mux` without an .app bundle),
/// since `UNUserNotificationCenter.current()` requires a bundle — so development runs don't crash and
/// only the packaged `TFA.app` actually posts notifications.
@MainActor
enum NotificationManager {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Ask once for permission (called at launch). Silent if unavailable; the system remembers the
    /// user's choice across launches.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a "<terminal> · 输出完成" notification. Silent if unavailable or not authorized (the
    /// system drops it). A unique id per post avoids coalescing distinct terminals' notifications.
    static func outputFinished(terminal: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = terminal
        content.body = "输出完成"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
