import SwiftUI

/// The dropdown's update announcement, the feature's primary surface: the
/// menu needs no permission, where Notification Center does — see
/// `UpdateScheduler`. The banner points at where the action is rather than
/// acting itself: installing has states (progress, failure, relaunch) that
/// belong to the About tab, and a Homebrew install is not this app's to
/// update.
struct UpdateBanner: View {
    let release: UpdateCheck.Release
    let openSettings: () -> Void

    /// Read once per construction rather than per render: it stats the
    /// Caskroom, and the banner only exists while an update is pending.
    private let installSource = InstallSource.current

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text("AgentTracker \(release.tag) is available")
                    .font(.system(size: 11, weight: .medium))
                Text(
                    installSource == .homebrew
                        ? "Update with brew upgrade --cask agent-tracker"
                        : "Install it from Settings › About."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installSource == .homebrew {
                Link("Release notes", destination: release.page)
                    .font(.system(size: 11))
            } else {
                Button("Open Settings") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
