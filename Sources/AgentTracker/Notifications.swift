import Foundation
import UserNotifications

/// The app's one door to Notification Center.
///
/// Two features post: a scheduled continue reporting what it did, and a session
/// asking for you. Both need the same three answers first — can this process
/// notify at all, has the user allowed it, does it still allow it now — so the
/// answers live in one place rather than being decided twice.
enum Notifications {
    /// `UNUserNotificationCenter.current()` **traps** in a process with no
    /// bundle identifier, and `swift run AgentTracker` is exactly that —
    /// verified: a plain SwiftPM executable reports a nil identifier. So every
    /// entry point checks first, and development builds simply do not notify.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Asked when the user switches something on, never when it fires.
    ///
    /// Same rule as the Automation grant: a permission prompt belongs at a
    /// moment the user is present for. At 04:00 it would sit unanswered, and
    /// the thing it was meant to announce would happen unannounced.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // A refusal is not an error worth surfacing here — every feature
            // that notifies has a visible fallback (the delivery log, the menu
            // bar icon itself), so nothing is lost but the banner.
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    /// Whether a notification posted right now would actually reach anyone.
    static var isPermitted: Bool {
        get async { await authorizationStatus() == .authorized }
    }
}
