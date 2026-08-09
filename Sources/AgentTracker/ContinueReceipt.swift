import Foundation
import UserNotifications

/// What happened when a scheduled continue came due.
///
/// Kept **outside** the schedule record, because a one-shot schedule is deleted
/// the moment it fires — before its outcome exists. Storing the outcome on the
/// record would mean the only deliveries you could review are the ones that
/// repeat.
///
/// A feature that acts while nobody is watching owes the user a receipt, and the
/// receipt has to outlive the thing that caused it.
struct ContinueReceipt: Equatable, Codable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        /// The message was written into the pane.
        case sent
        /// A gate said no. The common case, and not a malfunction.
        case refused
        /// Everything agreed it should be sent, and sending failed anyway.
        case failed

        var label: String {
            switch self {
            case .sent: return "Sent"
            case .refused: return "Not sent"
            case .failed: return "Failed"
            }
        }
    }

    /// Stable per receipt, so the list can be rendered without positional keys.
    var id: String
    var sessionId: String
    /// Whatever the row was calling this session, so a receipt still means
    /// something after the session is gone.
    var project: String
    var message: String
    var at: Date
    var outcome: Outcome
    /// The reason, verbatim from whichever gate refused or whatever failed.
    var detail: String

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        project: String,
        message: String,
        at: Date,
        outcome: Outcome,
        detail: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.message = message
        self.at = at
        self.outcome = outcome
        self.detail = detail
    }

    /// One line for the log and the row.
    var summary: String {
        outcome == .sent
            ? "\(outcome.label) \"\(message)\" to \(project)"
            : "\(outcome.label) to \(project): \(detail)"
    }
}

/// Tells the user something was sent on their behalf.
///
/// Ruben's call (2026-08-05): take the authorization prompt, because an automated
/// send always notifies and a menu bar the user is not looking at is not a
/// notification.
enum ContinueNotifier {
    /// Announces a receipt. Never throws and never blocks a delivery: the send
    /// already happened, and failing to tell the user about it must not undo or
    /// retry it.
    static func post(_ receipt: ContinueReceipt) async {
        guard Notifications.isAvailable, await Notifications.isPermitted else { return }
        let content = UNMutableNotificationContent()
        content.title =
            receipt.outcome == .sent
            ? "Resumed \(receipt.project)"
            : "Didn't resume \(receipt.project)"
        content.body =
            receipt.outcome == .sent
            ? "Sent \"\(receipt.message)\" when the usage limit reset."
            : receipt.detail
        content.sound = receipt.outcome == .sent ? .default : nil

        let request = UNNotificationRequest(
            identifier: receipt.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
