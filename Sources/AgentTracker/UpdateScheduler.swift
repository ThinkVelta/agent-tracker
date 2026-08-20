import Foundation
import UserNotifications

/// The automatic half of updates: one check at launch, one a day after.
///
/// The launch-time check is also the only moment automatic *installs* run —
/// nothing is in progress seconds after launch, so swapping the bundle and
/// relaunching there is the "install on next launch" the feature promises,
/// with no staged copy to manage. The daily check only ever announces:
/// restarting the app out from under a user mid-afternoon is not this
/// feature's call to make.
///
/// The dropdown is the announcement's primary surface, not Notification
/// Center: this feature never asks for notification permission (the ask
/// belongs to a moment the user opts into something, and checking is on by
/// default), so on a stock install a banner would silently never appear.
/// The menu needs no permission; a banner rides along when the user has
/// allowed banners for some other feature.
@MainActor
final class UpdateScheduler: ObservableObject {
    static let shared = UpdateScheduler()

    /// The newest release the last check found, when it beats this build.
    /// The dropdown renders it; cleared when a later check says up to date.
    @Published private(set) var available: UpdateCheck.Release?

    private var timer: Timer?
    /// One banner per discovered version, not one per day it stays
    /// undiscovered-and-uninstalled.
    private var notifiedVersion: String?

    func start() {
        // A development build has no bundle to swap and no version to compare.
        guard AppInfo.isBundled else { return }
        Task { await self.check(mayInstall: true) }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateScheduler.shared.check(mayInstall: false) }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(mayInstall: Bool) async {
        guard Preferences.shared.updateChecksAutomatically else { return }
        let outcome = await UpdateCheck.check(currentVersion: AppInfo.version)
        guard case .updateAvailable(let release) = outcome else {
            if case .upToDate = outcome { available = nil }
            return
        }

        if mayInstall, Preferences.shared.updateInstallsAutomatically,
            InstallSource.current == .direct
        {
            switch await Updater.downloadAndInstall(release) {
            case .installed:
                Updater.relaunch()
                return
            case .failed(let reason):
                // Fall through to the announcement: an update the user opted
                // into installing silently must not also fail silently.
                log("auto-install failed: \(reason)")
            }
        }
        available = release
        await notify(about: release)
    }

    private func notify(about release: UpdateCheck.Release) async {
        guard notifiedVersion != release.tag else { return }
        guard Notifications.isAvailable, await Notifications.isPermitted else { return }
        notifiedVersion = release.tag

        let content = UNMutableNotificationContent()
        content.title = "AgentTracker \(release.tag) is available"
        content.body =
            InstallSource.current == .homebrew
            ? "Update with: brew upgrade --cask agent-tracker"
            : "Install it from Settings › About."
        let request = UNNotificationRequest(
            identifier: "update-available-\(release.tag)",
            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func log(_ message: String) {
        print("[update] \(message)")
    }
}
