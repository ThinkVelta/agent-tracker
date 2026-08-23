import Foundation

/// Where everything the app remembers between launches is stored.
///
/// One place, because of what it has to do differently exactly once: while
/// rendering the README's images, none of it may be the author's.
///
/// The docs renderer runs the real app against synthetic sessions, but
/// preferences and marks live in `UserDefaults` rather than in the fixture — so
/// a render would pick up whoever regenerated the images: their icon mode,
/// their grouping, the sessions they had muted or pinned.
/// The committed picture would be of their setup, and the next person's
/// regeneration would silently change it back. An isolated suite, wiped on
/// entry, is what makes a render reproducible by anyone.
enum AppDefaults {
    static let shared: UserDefaults = {
        guard CommandLine.arguments.contains("--render-preview") else { return .standard }
        let name = "com.thinkvelta.agent-tracker.render-preview"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()
}
