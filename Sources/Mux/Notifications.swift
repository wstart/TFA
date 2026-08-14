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

    /// Post a precise command-finished notification (shell integration / OSC 133): carries the exit
    /// code and duration, e.g. "✓ 完成(exit 0 · 2分13秒)" — only for long background commands.
    static func commandFinished(terminal: String, exit: Int?, seconds: Double) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = terminal
        let mark = (exit ?? 0) == 0 ? "✓ 完成" : "✗ 失败"
        let code = exit.map { "exit \($0)" } ?? "exit ?"
        content.body = "\(mark)(\(code) · \(Self.duration(seconds)))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func duration(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return "\(t / 3600)时\((t % 3600) / 60)分" }
        if t >= 60 { return "\(t / 60)分\(t % 60)秒" }
        return "\(t)秒"
    }

    /// Post a "<terminal> 需要你的关注" notification — an agent rang the bell / sent an OSC notification
    /// while in the background (it finished and is waiting). Carries the message text when present.
    static func needsAttention(terminal: String, message: String?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "🔔 \(terminal)"
        content.body = (message?.isEmpty == false) ? message! : "需要你的关注"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
