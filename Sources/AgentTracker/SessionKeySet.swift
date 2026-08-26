import Combine
import Foundation

/// A remembered set of sessions, kept across launches and forgotten when its
/// sessions end.
///
/// Two features mark individual sessions — muting one so it stops asking, and
/// pinning one so it stays where you can see it — and both need the same
/// awkward rule underneath: a mark belongs to one session, so it must not
/// outlive it, and "not in the list right now" is not the same as "ended". That
/// rule is subtle enough to have been wrong once already; one implementation is
/// how it stays right for both.
@MainActor
final class SessionKeySet: ObservableObject {
    /// Mutes: a session told to stop asking. Its row displays idle, keeps its
    /// reason, and reads "Muted · …".
    static let muted = SessionKeySet(defaults: AppDefaults.shared, storageKey: "mutedSessions")
    /// Pins: a session held at the top of the list, whatever it is doing.
    static let pinned = SessionKeySet(defaults: AppDefaults.shared, storageKey: "pinnedSessions")

    /// `AgentSession.id`.
    @Published private(set) var keys: Set<String> = []

    /// How long a marked session must stay off the list before it is forgotten.
    ///
    /// The grace is the whole mechanism, because **absent is not ended**. A
    /// source that reports late — or a run that starts before the state files
    /// are read — would otherwise have its marks deleted during the gap,
    /// silently, and before the rows they belong to had appeared.
    ///
    /// Five minutes because the two failure directions are not symmetric. A
    /// mark forgotten too early costs the user a session that starts pulling at
    /// them again, or drops out of the place they put it, which they then have
    /// to notice and redo; a key kept too long costs a few bytes in
    /// `UserDefaults` and matches nothing, since session ids are UUIDs. So the
    /// grace is long enough to outlast any plausible hiccup in a source rather
    /// than tuned to the usual second or two.
    static let graceBeforeForgetting: TimeInterval = 300

    private let defaults: UserDefaults
    /// Readable so a test can hold the shipped names to account: renaming one
    /// silently drops everything every user has marked.
    let storageKey: String
    /// When each marked session was first noticed missing. In memory: a run
    /// that starts with the session already gone simply begins timing at
    /// launch, which is exactly what is wanted for a session that ended while
    /// the app was closed.
    private var absentSince: [String: Date] = [:]

    /// Its own key, never shared with another value in this domain, so two
    /// stores can never clobber each other's writes.
    init(defaults: UserDefaults = .standard, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        keys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func contains(_ sessionKey: String) -> Bool {
        keys.contains(sessionKey)
    }

    func toggle(_ sessionKey: String) {
        if keys.contains(sessionKey) {
            keys.remove(sessionKey)
        } else {
            keys.insert(sessionKey)
        }
        // Either direction starts the grace over. Unmarking must leave no
        // bookkeeping behind, and a session marked again must not inherit an
        // absence recorded before the user changed their mind — which would
        // have it forgotten the moment the old clock ran out.
        absentSince[sessionKey] = nil
        save()
    }

    /// Forgets sessions that have ended.
    ///
    /// - Parameters:
    ///   - liveKeys: every session currently on screen.
    ///   - now: the store's clock for this pass, so a mark and the row it
    ///     belongs to can never disagree about what "now" is.
    func reconcile(liveKeys: Set<String>, now: Date) {
        for key in keys where absentSince[key] == nil && !liveKeys.contains(key) {
            absentSince[key] = now
        }
        // A key that came back stops counting. Also drops entries for sessions
        // that have since been unmarked, so this map cannot outgrow the set it
        // describes.
        absentSince = absentSince.filter { keys.contains($0.key) && !liveKeys.contains($0.key) }

        let ended = keys.filter { key in
            guard let since = absentSince[key] else { return false }
            return now.timeIntervalSince(since) >= Self.graceBeforeForgetting
        }
        // Only on a real change: this runs on every store pass, and an
        // unconditional write would republish the set once a second and take
        // the whole dropdown with it.
        guard !ended.isEmpty else { return }
        absentSince = absentSince.filter { !ended.contains($0.key) }
        keys.subtract(ended)
        save()
    }

    private func save() {
        // Sorted so the stored value is stable and readable through
        // `defaults read`, which is how anyone diagnoses a row that will not
        // turn red or will not stay put.
        defaults.set(keys.sorted(), forKey: storageKey)
    }
}
