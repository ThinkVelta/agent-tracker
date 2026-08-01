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

    // MARK: - Idle folding

    /// When the popover's idle section folds itself away. Stored as one Int:
    /// -1 never, 0 always, n > 0 folds past n sessions.
    enum IdleFolding: Equatable, Hashable {
        case never
        case past(Int)
        case always

        var stored: Int {
            switch self {
            case .never: return -1
            case .always: return 0
            case .past(let threshold): return threshold
            }
        }

        init(stored: Int) {
            switch stored {
            case ..<0: self = .never
            case 0: self = .always
            default: self = .past(stored)
            }
        }

        var label: String {
            switch self {
            case .never: return "Never"
            case .always: return "Always"
            case .past(let threshold): return "When more than \(threshold)"
            }
        }

        /// The choices Settings offers. `.past(3)` is the shipped default.
        static let options: [IdleFolding] = [.never, .past(3), .past(5), .past(10), .always]
    }

    @Published var idleFolding: IdleFolding {
        didSet { defaults.set(idleFolding.stored, forKey: Keys.idleFolding) }
    }

    // MARK: - Auto-acknowledge dwell

    /// Seconds a terminal window must stay focused before its needs-you
    /// session counts as seen. 0 disables auto-acknowledge entirely.
    @Published var autoAckDwell: TimeInterval {
        didSet { defaults.set(autoAckDwell, forKey: Keys.autoAckDwell) }
    }

    static let dwellOptions: [(label: String, seconds: TimeInterval)] = [
        ("Off", 0), ("1 second", 1), ("3 seconds", 3), ("10 seconds", 10),
    ]

    // MARK: - Storage

    private enum Keys {
        static let appearance = "appearanceOverride"
        static let idleFolding = "idleFoldingThreshold"
        static let autoAckDwell = "autoAckDwellSeconds"
    }

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests run against their own suite and the
    /// real domain is never touched.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearanceOverride =
            AppearanceOverride(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
            ?? .system
        // Loaded values are read type-checked (never via integer/double(forKey:),
        // whose coercion turns a stored "oops" into 0 — which is a REAL option
        // here) and then snapped to the option sets Settings offers: a value
        // with no matching picker tag renders as a BLANK picker, which is
        // worse than losing the stored value.
        let defaultFolding = IdleFolding.past(Theme.Metrics.idleAutoCollapseThreshold)
        let loadedFolding = (defaults.object(forKey: Keys.idleFolding) as? Int)
            .map(IdleFolding.init(stored:))
        idleFolding =
            loadedFolding.flatMap { IdleFolding.options.contains($0) ? $0 : nil }
            ?? defaultFolding

        let loadedDwell = defaults.object(forKey: Keys.autoAckDwell) as? Double
        autoAckDwell =
            loadedDwell.flatMap { dwell in
                Self.dwellOptions.contains { $0.seconds == dwell } ? dwell : nil
            } ?? TerminalFocusObserver.defaultDwell
    }
}
