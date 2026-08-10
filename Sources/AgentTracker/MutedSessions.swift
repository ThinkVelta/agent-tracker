import Combine
import Foundation

/// Which sessions have been told to stop asking.
///
/// A long-running background agent that finishes a turn every few minutes is
/// the case this exists for: it is doing exactly what it should, and every
/// completion turns the menu bar red for something nobody intends to look at.
/// Muting one is the user saying "I will check on this myself".
///
/// **Mute is a standing acknowledgement, not a hidden state.** A muted session
/// that would be needs-you displays as idle, keeping the reason it gave — so
/// the row still reads "Approve Bash?" and says it is muted, rather than
/// pretending nothing is happening. Every count, section and notification then
/// agrees, because they all read the state. Acknowledgement already works this
/// way (`SessionStore.applyAcknowledgement`); this is the same move made
/// durable and reversible.
@MainActor
final class MutedSessions: ObservableObject {
    static let shared = MutedSessions()

    /// `AgentSession.id`.
    @Published private(set) var muted: Set<String> = []

    /// Its own key, never shared with another value in this domain — the
    /// schedules learned that the hard way.
    static let storageKey = "mutedSessions"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        muted = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isMuted(_ sessionKey: String) -> Bool {
        muted.contains(sessionKey)
    }

    func toggle(_ sessionKey: String) {
        if muted.contains(sessionKey) {
            muted.remove(sessionKey)
        } else {
            muted.insert(sessionKey)
        }
        // Either direction starts the grace over. Unmuting must leave no
        // bookkeeping behind, and a session muted again must not inherit an
        // absence recorded before the user changed their mind — which would
        // have it forgotten the moment the old clock ran out.
        absentSince[sessionKey] = nil
        save()
    }

    /// How long a muted session must stay off the list before its mute is
    /// forgotten.
    ///
    /// The grace is the whole mechanism, because **absent is not ended**. A
    /// source that reports late — or a run that starts before the state files
    /// are read — would otherwise have its mutes deleted during the gap,
    /// silently, and before the rows they belong to had appeared.
    ///
    /// Five minutes because the two failure directions are not symmetric. A
    /// mute forgotten too early costs the user a session that starts pulling at
    /// them again, which they then have to notice and redo; a key kept too long
    /// costs a few bytes in `UserDefaults` and matches nothing, since both
    /// providers issue UUIDs. So the grace is set long enough to outlast any
    /// plausible hiccup in a source rather than tuned to the scanner's usual
    /// second or two.
    static let graceBeforeForgetting: TimeInterval = 300

    /// When each muted session was first noticed missing. In memory: a run that
    /// starts with the session already gone simply begins timing at launch,
    /// which is exactly the behaviour wanted for a session that ended while the
    /// app was closed.
    private var absentSince: [String: Date] = [:]

    /// Forgets sessions that have ended.
    ///
    /// A session id belongs to one run, so a mute cannot outlive it: the next
    /// session in that directory is a different one and has not asked to be
    /// ignored. Left unpruned the list would also grow forever.
    ///
    /// - Parameters:
    ///   - liveKeys: every session currently on screen.
    ///   - now: the store's clock for this pass, so a mute and the row it
    ///     belongs to can never disagree about what "now" is.
    func reconcile(liveKeys: Set<String>, now: Date) {
        for key in muted where absentSince[key] == nil && !liveKeys.contains(key) {
            absentSince[key] = now
        }
        // A key that came back stops counting. Also drops entries for sessions
        // that have since been unmuted, so this map cannot outgrow the set it
        // describes.
        absentSince = absentSince.filter { muted.contains($0.key) && !liveKeys.contains($0.key) }

        let ended = muted.filter { key in
            guard let since = absentSince[key] else { return false }
            return now.timeIntervalSince(since) >= Self.graceBeforeForgetting
        }
        // Only on a real change: this runs on every store pass, and an
        // unconditional write would republish the set once a second and take
        // the whole dropdown with it.
        guard !ended.isEmpty else { return }
        absentSince = absentSince.filter { !ended.contains($0.key) }
        muted.subtract(ended)
        save()
    }

    private func save() {
        // Sorted so the stored value is stable and readable through
        // `defaults read`, which is how anyone diagnoses a row that will not
        // turn red.
        defaults.set(muted.sorted(), forKey: Self.storageKey)
    }
}
