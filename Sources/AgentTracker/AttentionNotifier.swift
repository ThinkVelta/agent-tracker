import Foundation
import UserNotifications

/// A session asking for you, worded the way its row is.
///
/// Derived rather than composed at the call site so the banner and the row can
/// never describe the same session differently.
struct AttentionAlert: Equatable {
    /// `AgentSession.id`. Doubles as the notification's identifier, so a
    /// session can only ever have one alert standing, and as the name of the
    /// row to raise when that alert is clicked.
    var sessionKey: String
    var title: String
    var subtitle: String
    var body: String

    init(session: AgentSession) {
        sessionKey = session.id
        title = session.displayName
        // The row's metadata line minus its reason, which is the body here.
        // Location earns its place for the same reason it does there: several
        // sessions in one repo otherwise arrive as identical banners.
        subtitle = [session.providerDisplayName, session.locationContext]
            .compactMap { $0 }
            .joined(separator: " · ")
        body = session.reason ?? SessionState.needsYou.label
    }
}

/// Which sessions have newly started asking for you, and which have stopped.
///
/// The signal is a **flip**, not a state. A needs-you session stays needs-you
/// until someone acknowledges it, and the store republishes on every hook event
/// and every timer tick, so notifying on the state would be notifying once a
/// second. Kept apart from the notifier so the rule is testable without a
/// notification centre.
struct AttentionTracker {
    struct Changes: Equatable {
        /// Newly needs-you, in the order the store published them.
        var began: [AttentionAlert] = []
        /// Session keys that have stopped needing you, including sessions that
        /// ended outright.
        var ended: [String] = []

        var isEmpty: Bool { began.isEmpty && ended.isEmpty }
    }

    private let since: Date
    private var needing: Set<String> = []

    /// - Parameter since: when this app started watching. Sessions that turned
    ///   red before that are never announced — launching into red sessions is
    ///   not news, the same exemption the icon's pulse makes for its first
    ///   render. Stated as a moment rather than as "skip the first pass"
    ///   because the two are not equivalent here: the Codex scanner's first
    ///   results land a beat *after* launch, so a first-pass baseline alone
    ///   would let every already-red Codex session through as a banner.
    init(since: Date = Date()) {
        self.since = since
    }

    mutating func update(with sessions: [AgentSession]) -> Changes {
        let previous = needing
        needing = Set(sessions.filter { $0.state == .needsYou }.map(\.id))
        return Changes(
            began:
                sessions
                .filter {
                    $0.state == .needsYou && !previous.contains($0.id)
                        && ($0.stateChangedAt ?? .distantPast) >= since
                }
                .map(AttentionAlert.init(session:)),
            // Sorted only so the result is comparable in a test — the order a
            // set difference yields is otherwise arbitrary.
            ended: previous.subtracting(needing).sorted())
    }
}

/// Tells the user a session wants them, for the times they are not looking at
/// the menu bar.
///
/// Deliberately **not** time-sensitive: the default interruption level is what
/// lets Focus and Do Not Disturb hold these back, and a banner about your own
/// background work has not earned the right to break through those.
enum AttentionNotifier {
    /// Where `post` stashes the row to raise if the banner is clicked.
    static let sessionKeyField = "sessionKey"

    static func post(_ alert: AttentionAlert) async {
        guard Notifications.isAvailable, await Notifications.isPermitted else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.userInfo = [sessionKeyField: alert.sessionKey]
        // The session's own key as the identifier: a later alert for a session
        // replaces its earlier one instead of stacking another copy behind it.
        let request = UNNotificationRequest(
            identifier: alert.sessionKey, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Takes a session's banner back once it has stopped needing anyone —
    /// usually because the user went to the terminal, which is exactly when one
    /// still sitting in Notification Center has become misinformation.
    static func withdraw(_ sessionKeys: [String]) {
        guard Notifications.isAvailable, !sessionKeys.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: sessionKeys)
        center.removePendingNotificationRequests(withIdentifiers: sessionKeys)
    }
}
