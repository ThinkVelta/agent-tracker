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

    /// Pure given its inputs, so tests cover every combination without a
    /// Caskroom on the test machine.
    static func detect(
        isBundled: Bool,
        directoryExists: (String) -> Bool
    ) -> InstallSource {
        guard isBundled else { return .development }
        return caskroomDirectories.contains(where: directoryExists) ? .homebrew : .direct
    }

    static var current: InstallSource {
        detect(isBundled: AppInfo.isBundled) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
