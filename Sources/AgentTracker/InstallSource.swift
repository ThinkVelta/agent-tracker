import Foundation

/// Where this copy of the app came from, which decides who updates it.
///
/// A Homebrew-managed bundle must never self-update: the app sits in
/// /Applications but brew's Caskroom holds the manifest saying which version
/// is installed, so a self-swap would leave `brew list --versions` lying and
/// the next `brew upgrade` fighting the bundle. Detection is therefore not an
/// optimization — every update path checks it first.
enum InstallSource: Equatable {
    /// A Caskroom directory exists for this cask: brew owns the bundle and
    /// `brew upgrade --cask agent-tracker` is the updater.
    case homebrew
    /// Downloaded and dragged in by hand; the app may update itself.
    case direct
    /// Not a bundle at all (`swift run`); updating is meaningless.
    case development

    /// The two default prefixes (Apple Silicon, Intel). A custom
    /// HOMEBREW_PREFIX is invisible to an app launched from Finder — that
    /// environment lives in brew's shells — so a custom-prefix install is
    /// treated as direct. The failure mode is a stale brew manifest for a
    /// setup whose owner chose to be nonstandard, and the alternative is
    /// spawning `brew --prefix` at every launch for everyone.
    static let caskroomDirectories = [
        "/opt/homebrew/Caskroom/agent-tracker",
        "/usr/local/Caskroom/agent-tracker",
    ]

    /// The one path brew's cask actually manages. The Caskroom holds only
    /// metadata; the app itself is moved here — so a bundle running from
    /// anywhere else cannot be the brew-managed copy, however many Caskroom
    /// entries exist beside it. (A custom --appdir is invisible to an app
    /// launched from Finder, the same tradeoff as a custom prefix.)
    static let homebrewManagedBundlePath = "/Applications/AgentTracker.app"

    /// Pure given its inputs, so tests cover every combination without a
    /// Caskroom on the test machine. Both conditions, deliberately: the
    /// Caskroom entry says brew believes it manages this cask, and the bundle
    /// path says this running copy is the one it manages. A direct copy in
    /// ~/Applications beside a stale Caskroom entry is a direct install.
    static func detect(
        isBundled: Bool,
        bundlePath: String,
        directoryExists: (String) -> Bool
    ) -> InstallSource {
        guard isBundled else { return .development }
        guard bundlePath == homebrewManagedBundlePath else { return .direct }
        return caskroomDirectories.contains(where: directoryExists) ? .homebrew : .direct
    }

    static var current: InstallSource {
        detect(
            isBundled: AppInfo.isBundled,
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path
        ) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
