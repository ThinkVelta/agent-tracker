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
        case forgetPreferences
        case brewUninstall
        case trashBundle
    }

    /// A development build keeps its preferences: `swift run` is a workbench,
    /// and wiping the workbench's settings on every uninstall rehearsal would
    /// punish exactly the person testing this.
    static func plan(for source: InstallSource) -> [Step] {
        switch source {
        case .homebrew:
            return [.unhookAgents, .disableLoginItem, .forgetPreferences, .brewUninstall]
        case .direct:
            return [.unhookAgents, .disableLoginItem, .forgetPreferences, .trashBundle]
        case .development:
            return [.unhookAgents]
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
        guard let script = uninstallScriptURL() else {
            return .failed(
                "No uninstall script found; run ./integrations/uninstall.sh from the repo.")
        }
        // --hooks-only is the whole contract with the script: the full run
        // kills this very process and removes the bundle itself, bypassing
        // brew's ownership — everything app-shaped is this type's job.
        let unhook = await ProcessRunner.run("/bin/bash", [script.path, "--hooks-only"])
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
            case .forgetPreferences:
                // After the login item and before the bundle goes: nothing
                // rewrites preferences from here on, so the domain stays gone.
                if let bundleID = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                }
            case .brewUninstall:
                guard let brew = await InstallSource.owningHomebrewExecutable() else {
                    return .failed("No Homebrew prefix claims this cask.")
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

    /// The bundled script first, then the repo's own, so `.development` is
    /// reachable too: under `swift run` the working directory is the repo
    /// root, which is exactly the population that plan serves. A GUI launch
    /// never reaches the fallback, because a bundle always resolves first and
    /// a GUI process's working directory is nowhere useful anyway.
    static func uninstallScriptURL() -> URL? {
        if AppInfo.isBundled {
            let bundled = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/integrations/uninstall.sh")
            return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
        }
        let repoScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("integrations/uninstall.sh")
        return FileManager.default.fileExists(atPath: repoScript.path) ? repoScript : nil
    }

    private static func tail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(2)
        return lines.joined(separator: " ")
    }
}
