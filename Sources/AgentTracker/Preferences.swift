import AppKit
import SwiftUI

/// The app's one preferences store: every persisted setting lives here, typed,
/// with its default. Views observe it; nothing else reads UserDefaults
/// directly, so "where is this configured?" always has the same answer.
///
/// Unknown or corrupt stored values fall back to the default rather than
/// crashing or half-applying — the store must survive whatever an old build,
/// a defaults-write experiment, or a future version left behind.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // MARK: - Appearance

    enum AppearanceOverride: String, CaseIterable {
        case system
        case light
        case dark

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// nil means "follow the system" — assigning nil to `NSApp.appearance`
        /// is exactly that.
        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var appearanceOverride: AppearanceOverride {
        didSet {
            defaults.set(appearanceOverride.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Applies to every window this app owns — popover, settings, onboarding.
    func applyAppearance() {
        // NSApp is nil where no application object exists (the test runner);
        // there is nothing to restyle there.
        guard let app = NSApp else { return }
        app.appearance = appearanceOverride.appearance
    }

    // MARK: - Grouping

    /// What the dropdown's sections divide on. State by default: the app's
    /// question is "which one needs me", and that is a state.
    @Published var grouping: SessionSections.Grouping {
        didSet { defaults.set(grouping.rawValue, forKey: Keys.grouping) }
    }

    // MARK: - Refresh cadence

    /// How often the safety-net reload runs. Session *events* arrive by
    /// watcher instantly regardless — this only paces the janitor pass that
    /// prunes dead sessions and refreshes relative timestamps, which is why
    /// there is no sub-second option: it would burn cycles buying nothing.
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    static let refreshOptions: [(label: String, seconds: TimeInterval)] = [
        ("1 second", 1), ("5 seconds", 5), ("10 seconds", 10),
        ("30 seconds", 30), ("60 seconds", 60),
    ]

    // MARK: - Auto-acknowledge dwell

    /// Seconds a terminal window must stay focused before its needs-you
    /// session counts as seen. 0 disables auto-acknowledge entirely.
    @Published var autoAckDwell: TimeInterval {
        didSet { defaults.set(autoAckDwell, forKey: Keys.autoAckDwell) }
    }

    static let dwellOptions: [(label: String, seconds: TimeInterval)] = [
        ("Off", 0), ("1 second", 1), ("3 seconds", 3), ("10 seconds", 10),
    ]

    // MARK: - Stale background shells

    /// How long a turn that ended with a background shell still running may
    /// show as running before the row goes red for the shell. A stuck shell
    /// never wakes the session, and this is the only thing that says so.
    /// 0 disables the check.
    @Published var staleShellAfter: TimeInterval {
        didSet { defaults.set(staleShellAfter, forKey: Keys.staleShellAfter) }
    }

    static let staleShellOptions: [(label: String, seconds: TimeInterval)] = [
        ("Off", 0), ("10 minutes", 600), ("30 minutes", 1800), ("1 hour", 3600),
    ]

    /// Long enough for a build, a test suite or a CI poll to finish on its own.
    static let defaultStaleShellAfter: TimeInterval = 1800

    // MARK: - Menu bar icon

    /// What the menu bar icon draws (see `StatusIconRenderer.Mode`).
    @Published var iconMode: StatusIconRenderer.Mode {
        didSet { defaults.set(iconMode.rawValue, forKey: Keys.iconMode) }
    }

    /// Whether it draws tinted-template instead of colored. Orthogonal to
    /// `iconMode`: every mode has a monochrome rendering.
    @Published var monochromeIcon: Bool {
        didSet { defaults.set(monochromeIcon, forKey: Keys.monochromeIcon) }
    }

    /// The brief one-shot pulse when a session flips to needs-you.
    @Published var attentionCue: Bool {
        didSet { defaults.set(attentionCue, forKey: Keys.attentionCue) }
    }

    // MARK: - Notifications

    /// Whether a session flipping to needs-you posts a notification.
    ///
    /// Off by default, and opt-in rather than opt-out: the menu bar icon is
    /// already the passive channel this app was built to be, and a banner is
    /// the most intrusive thing it can do. Someone who wants to be interrupted
    /// can say so; someone who installed a menu bar app probably did not.
    @Published var notifyNeedsYou: Bool {
        didSet { defaults.set(notifyNeedsYou, forKey: Keys.notifyNeedsYou) }
    }

    // MARK: - Scheduled continues

    /// Whether a session may be armed to resume itself when its usage window
    /// resets. Off by default and deliberately its own switch: everything else
    /// here changes what the app *shows*, and this is the only one that lets it
    /// act on a session while nobody is watching.
    ///
    /// Only the gate lives here. The armed schedules do not: `objectWillChange`
    /// on this object re-renders the menu bar icon, so an editable message would
    /// redraw it on every keystroke. They live in `ContinueSchedules`.
    @Published var scheduledContinues: Bool {
        didSet { defaults.set(scheduledContinues, forKey: Keys.scheduledContinues) }
    }

    // MARK: - Updates

    /// One GitHub API request at launch and daily. On by default because the
    /// result is a notification, not an action — and the README names this as
    /// the app's only unprompted network request, so changing what it does
    /// means changing that sentence too.
    @Published var updateChecksAutomatically: Bool {
        didSet { defaults.set(updateChecksAutomatically, forKey: Keys.updateChecks) }
    }

    /// Install what the launch-time check finds, without asking. Off by
    /// default: it swaps the running app. Meaningless (and ignored) for
    /// Homebrew installs, which `brew upgrade` owns.
    @Published var updateInstallsAutomatically: Bool {
        didSet { defaults.set(updateInstallsAutomatically, forKey: Keys.updateInstalls) }
    }

    // MARK: - Quit confirmation

    /// Ask before quitting from the panel's power button. Turned off by the
    /// alert's own "don't ask again" checkbox; Settings › General re-enables.
    @Published var confirmQuit: Bool {
        didSet { defaults.set(confirmQuit, forKey: Keys.confirmQuit) }
    }

    // MARK: - Storage

    private enum Keys {
        static let appearance = "appearanceOverride"
        static let grouping = "sessionGrouping"
        static let autoAckDwell = "autoAckDwellSeconds"
        static let staleShellAfter = "staleShellAfterSeconds"
        static let refreshInterval = "refreshIntervalSeconds"
        static let confirmQuit = "confirmQuit"
        static let iconMode = "iconMode"
        static let monochromeIcon = "monochromeIcon"
        static let attentionCue = "attentionCue"
        static let notifyNeedsYou = "notifyNeedsYou"
        static let scheduledContinues = "scheduledContinues"
        static let updateChecks = "updateChecksAutomatically"
        static let updateInstalls = "updateInstallsAutomatically"
    }

    /// The mode 0.1.0 stored when monochrome was one of the icon modes rather
    /// than a switch across all of them.
    static let legacyMonochromeMode = "monochrome"

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests run against their own suite and the
    /// real domain is never touched. The default is `AppDefaults.shared` rather
    /// than `.standard` so a docs render does not inherit the settings of
    /// whoever regenerated the images.
    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        appearanceOverride =
            AppearanceOverride(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
            ?? .system
        // Loaded values are read type-checked (never via integer/double(forKey:),
        // whose coercion turns a stored "oops" into 0 — which is a REAL option
        // here) and then snapped to the option sets Settings offers: a value
        // with no matching picker tag renders as a BLANK picker, which is
        // worse than losing the stored value.

        let loadedDwell = defaults.object(forKey: Keys.autoAckDwell) as? Double
        autoAckDwell =
            loadedDwell.flatMap { dwell in
                Self.dwellOptions.contains { $0.seconds == dwell } ? dwell : nil
            } ?? TerminalFocusObserver.defaultDwell

        let loadedStale = defaults.object(forKey: Keys.staleShellAfter) as? Double
        staleShellAfter =
            loadedStale.flatMap { stale in
                Self.staleShellOptions.contains { $0.seconds == stale } ? stale : nil
            } ?? Self.defaultStaleShellAfter

        let loadedInterval = defaults.object(forKey: Keys.refreshInterval) as? Double
        refreshInterval =
            loadedInterval.flatMap { interval in
                Self.refreshOptions.contains { $0.seconds == interval } ? interval : nil
            } ?? SessionStore.defaultRefreshInterval

        grouping =
            SessionSections.Grouping(rawValue: defaults.string(forKey: Keys.grouping) ?? "")
            ?? .state
        confirmQuit = defaults.object(forKey: Keys.confirmQuit) as? Bool ?? true

        // Monochrome used to BE a mode; it is now a switch crossed with every
        // mode. Its old rendering was dots-and-counts, so mapping it onto the
        // default mode with the switch on leaves an upgrader's menu bar looking
        // exactly as it did. Rewritten here rather than translated on every
        // read, or turning the switch off would be undone by the next launch.
        let storedMode = defaults.string(forKey: Keys.iconMode)
        let upgradingFromMonochromeMode = storedMode == Self.legacyMonochromeMode
        let mode =
            (upgradingFromMonochromeMode ? nil : storedMode)
            .flatMap(StatusIconRenderer.Mode.init(rawValue:)) ?? .dotsAndCounts
        iconMode = mode
        monochromeIcon =
            upgradingFromMonochromeMode
            || (defaults.object(forKey: Keys.monochromeIcon) as? Bool ?? false)
        if upgradingFromMonochromeMode {
            defaults.set(mode.rawValue, forKey: Keys.iconMode)
            defaults.set(true, forKey: Keys.monochromeIcon)
        }

        attentionCue = defaults.object(forKey: Keys.attentionCue) as? Bool ?? true
        notifyNeedsYou = defaults.object(forKey: Keys.notifyNeedsYou) as? Bool ?? false
        scheduledContinues = defaults.object(forKey: Keys.scheduledContinues) as? Bool ?? false
        updateChecksAutomatically =
            defaults.object(forKey: Keys.updateChecks) as? Bool ?? true
        updateInstallsAutomatically =
            defaults.object(forKey: Keys.updateInstalls) as? Bool ?? false
    }
}
