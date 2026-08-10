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

    /// `AgentSession.id`, so a Claude and a Codex session that somehow shared a
    /// session id could not mute each other.
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
        save()
    }

    /// Muted sessions this run has actually seen on screen. In memory only, and
    /// the whole reason `reconcile` is not a one-line intersection.
    private var seenLive: Set<String> = []

    /// Forgets sessions that have ended.
    ///
    /// A session id belongs to one run, so a mute cannot outlive it: the next
    /// session in that directory is a different one and has not asked to be
    /// ignored. Left unpruned the list would also grow forever.
    ///
    /// **Absent is not ended.** A mute for a session this run has never seen is
    /// left alone, because the two are different things for a good part of a
    /// second: the Codex scanner publishes its first rows a beat after launch,
    /// so intersecting with the live set on every pass would delete every Codex
    /// mute during the gap — silently, and before the row it belongs to ever
    /// appeared. A key is only dropped once it has been watched leaving.
    ///
    /// The cost of that caution is a mute set while the app is running and
    /// still stored after a quit that beat the session's own exit. One stale
    /// key, which the next run drops as soon as its session is seen and gone.
    ///
    /// - Parameter liveKeys: every session currently on screen.
    func reconcile(liveKeys: Set<String>) {
        let ended = seenLive.subtracting(liveKeys)
        seenLive.formUnion(muted.intersection(liveKeys))
        guard !ended.isEmpty else { return }
        seenLive.subtract(ended)
        let survivors = muted.subtracting(ended)
        // Only on a real change: this runs on every store pass, and an
        // unconditional write would republish the set once a second and take
        // the whole dropdown with it.
        guard survivors != muted else { return }
        muted = survivors
        save()
    }

    private func save() {
        // Sorted so the stored value is stable and readable through
        // `defaults read`, which is how anyone diagnoses a row that will not
        // turn red.
        defaults.set(muted.sorted(), forKey: Self.storageKey)
    }
}
