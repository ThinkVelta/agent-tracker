import AppKit
import Foundation

/// One-click uninstall, from Settings. The bundle already carries
/// `integrations/uninstall.sh` (the same script the repo offers), so the app
/// can unhook the agents without a checkout anywhere; what remains is the
/// login item and the bundle itself, and who removes the bundle depends on
/// who owns it.
enum Uninstaller {
    /// The steps for an install source, pure so the plan is testable: a brew
    /// bundle is brew's to remove (self-deleting it would strand the cask
    /// manifest), a direct bundle goes to the Trash, and a development build
    /// has no bundle at all, so only the hooks are cleaned.
    enum Step: Equatable {
        case unhookAgents
        case disableLoginItem
        case brewUninstall
        case trashBundle
    }

    static func plan(for source: InstallSource) -> [Step] {
        switch source {
        case .homebrew: return [.unhookAgents, .disableLoginItem, .brewUninstall]
        case .direct: return [.unhookAgents, .disableLoginItem, .trashBundle]
        case .development: return [.unhookAgents]
        }
    }

    enum Outcome: Equatable {
        /// Everything ran; the caller terminates the app.
        case done
        case failed(String)
    }

    /// Session data in `~/.agent-tracker` is deliberately kept, matching the
    /// script's own default: removing a directory of the user's data is not
    /// this button's decision to make.
    static func run() async -> Outcome {
        guard let script = bundledUninstallScript() else {
            return .failed(
                "No bundled uninstall script; run ./integrations/uninstall.sh from the repo.")
        }
        let unhook = await ProcessRunner.run("/bin/bash", [script.path])
        guard unhook.ok else {
            return .failed("Unhooking failed: \(tail(unhook.output))")
        }

        for step in plan(for: InstallSource.current).dropFirst() {
            switch step {
            case .unhookAgents:
                continue
            case .disableLoginItem:
                // Best effort: an unregistered login item on a trashed app is
                // inert either way, but leaving no trace is the polite exit.
                try? LoginItem.setEnabled(false)
            case .brewUninstall:
                guard let brew = InstallSource.homebrewExecutable() else {
                    return .failed("Homebrew's executable was not found.")
                }
                let result = await ProcessRunner.run(
                    brew, ["uninstall", "--cask", "agent-tracker"],
                    environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                guard result.ok else {
                    return .failed("brew uninstall failed: \(tail(result.output))")
                }
            case .trashBundle:
                do {
                    try FileManager.default.trashItem(
                        at: Bundle.main.bundleURL, resultingItemURL: nil)
                } catch {
                    return .failed(
                        "Could not move the app to the Trash: \(error.localizedDescription)")
                }
            }
        }
        return .done
    }

    /// The script every bundle carries. nil under `swift run`, which has no
    /// bundle and whose user has the repo in front of them.
    static func bundledUninstallScript() -> URL? {
        guard AppInfo.isBundled else { return nil }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/integrations/uninstall.sh")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func tail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(2)
        return lines.joined(separator: " ")
    }
}
