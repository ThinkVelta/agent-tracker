import SwiftUI

/// The dropdown's update announcement, the feature's primary surface: the
/// menu needs no permission, where Notification Center does — see
/// `UpdateScheduler`. The banner points at where the action is rather than
/// acting itself: installing has states (progress, failure, relaunch) that
/// belong to the About tab, and a Homebrew install is not this app's to
/// update.
struct UpdateBanner: View {
    let release: UpdateCheck.Release
    /// Closes the dropdown panel before Settings opens, or the non-activating
    /// panel sits over the Settings window — the same hazard the footer gear
    /// documents and handles this way.
    let dismiss: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text("AgentTracker \(release.tag) is available")
                    .font(.system(size: 11, weight: .medium))
                Text("Install it from Settings › About.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") {
                dismiss()
                SettingsRouter.shared.show(.about) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
