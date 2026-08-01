import AppKit
import SwiftUI

/// The Settings window: the conventional SwiftUI `Settings` scene with tabs —
/// the surface is small, so the sidebar-window shape (à la Stats) would be
/// chrome without content. Sections are grouped cards in the shape the
/// facelift established: radius 10, whisper fill, hairline-separated rows,
/// title left / control right.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            SessionsSettingsTab()
                .tabItem { Label("Sessions", systemImage: "circle.grid.2x1") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
    }
}

/// Preview-only (`--render-preview --view settings`): the tabs stacked without
/// `TabView`, which is AppKit-backed and rasterizes to nothing in
/// `ImageRenderer`. Controls still render as placeholder bars — the point is
/// checking the cards, copy and spacing, not the widgets.
struct SettingsPreviewStack: View {
    var body: some View {
        VStack(spacing: 0) {
            GeneralSettingsTab()
            Divider()
            MenuBarSettingsTab()
            Divider()
            SessionsSettingsTab()
            Divider()
            AboutSettingsTab()
        }
        .frame(width: 440)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    /// The user can change login-item state behind our back in System
    /// Settings; re-reading while visible keeps the switch truthful.
    private let statusTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard {
                SettingsRow(
                    title: "Start at login",
                    detail: LoginItem.isSupported
                        ? "Launch AgentTracker when you sign in."
                        : "Needs the installed app — run `make install` first."
                ) {
                    Toggle("", isOn: loginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LoginItem.isSupported)
                }
                SettingsRow(
                    title: "Confirm before quitting",
                    detail: "The panel's power button asks first. The alert's "
                        + "\u{201C}don't ask again\u{201D} turns this off; re-enable it here.",
                    divided: true
                ) {
                    Toggle("", isOn: $preferences.confirmQuit)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            SettingsCard {
                SettingsRow(
                    title: "Appearance",
                    detail: "How the dropdown and windows draw, independent of the system."
                ) {
                    Picker("", selection: $preferences.appearanceOverride) {
                        ForEach(Preferences.AppearanceOverride.allCases, id: \.self) {
                            Text($0.label)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(
                    title: "Fold idle sessions away",
                    detail: "Idle sessions collapse into their header so active work stays "
                        + "visible. Filtering or searching always expands them.",
                    divided: true
                ) {
                    Picker("", selection: $preferences.idleFolding) {
                        ForEach(Preferences.IdleFolding.options, id: \.self) {
                            Text($0.label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
        .padding(20)
        .onReceive(statusTick) { _ in launchAtLogin = LoginItem.isEnabled }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                try? LoginItem.setEnabled(wanted)
                // Reflect reality, not intent — never show "on" while unbound.
                launchAtLogin = LoginItem.isEnabled
            })
    }
}

// MARK: - Menu bar

private struct MenuBarSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared

    /// Previews render the REAL StatusIconRenderer output, so they can never
    /// drift from what the menu bar draws. One sample with a red group, a
    /// green tally, and a dimmed zero — every visual treatment on display.
    private static let sampleCounts: SessionCounts = {
        var counts = SessionCounts()
        counts.needsYou = 1
        counts.running = 4
        counts.idle = 0
        return counts
    }()

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon")
                        .font(.system(size: 13))
                    Text("How the menu bar item spends its space.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $preferences.iconMode) {
                        ForEach(StatusIconRenderer.Mode.allCases, id: \.self) { mode in
                            HStack(spacing: 8) {
                                Image(
                                    nsImage: StatusIconRenderer.render(
                                        for: Self.sampleCounts, mode: mode
                                    ).image)
                                Text(mode.label)
                                    .font(.system(size: 12))
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            SettingsCard {
                SettingsRow(
                    title: "Pulse when a session needs you",
                    detail: "One brief pulse of the red dot when a session flips to "
                        + "needs-you. Never animates continuously; disabled automatically "
                        + "when Reduce Motion is on."
                ) {
                    Toggle("", isOn: $preferences.attentionCue)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Sessions

private struct SessionsSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard {
                SettingsRow(
                    title: "Auto-acknowledge after",
                    detail: "Visiting a session's terminal yourself clears its red state once "
                        + "the window has been focused this long."
                ) {
                    Picker("", selection: $preferences.autoAckDwell) {
                        ForEach(Preferences.dwellOptions, id: \.seconds) { option in
                            Text(option.label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @State private var accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
    @State private var updateState: UpdateState = .idle
    @State private var copiedUninstall = false

    private let statusTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum UpdateState: Equatable {
        case idle
        case checking
        case done(UpdateCheck.Outcome)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            SettingsCard {
                SettingsRow(
                    title: "Accessibility",
                    detail: accessibilityGranted
                        ? "Granted — click-to-focus can raise terminal windows."
                        : "Not granted. If AgentTracker is already listed, remove it with − "
                            + "and add it again — a rebuilt app invalidates its old grant."
                ) {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings…") { TerminalFocuser.openAccessibilitySettings() }
                    }
                }
                SettingsRow(title: "Updates", detail: updateDetail, divided: true) {
                    updateAccessory
                }
                SettingsRow(
                    title: "Uninstall",
                    detail: "Removes the hooks, the app and its settings. From the repo:\n"
                        + "./integrations/uninstall.sh",
                    divided: true
                ) {
                    Button(copiedUninstall ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "./integrations/uninstall.sh", forType: .string)
                        copiedUninstall = true
                    }
                }
            }
            Link(
                "github.com/ThinkVelta/agent-tracker",
                destination: URL(string: "https://github.com/ThinkVelta/agent-tracker")!
            )
            .font(Theme.Typography.footer)
        }
        .padding(20)
        .onReceive(statusTick) { _ in
            accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 12, height: 12)
                Circle().fill(.green).frame(width: 12, height: 12)
                Circle().fill(.gray).frame(width: 12, height: 12)
            }
            Text("AgentTracker")
                .font(.system(size: 15, weight: .bold))
            Text(versionLine)
                .font(Theme.Typography.footer)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var versionLine: String {
        guard AppInfo.isBundled else { return "development build (swift run)" }
        let build = AppInfo.build.map { " (\($0))" } ?? ""
        return "Version \(AppInfo.version)\(build)"
    }

    private var updateDetail: String {
        switch updateState {
        case .idle: return "Checks the GitHub releases page. Nothing runs in the background."
        case .checking: return "Checking…"
        case .done(.upToDate): return "You're on the latest release."
        case .done(.updateAvailable(let version, _)): return "\(version) is available."
        case .done(.noReleases): return "No releases published yet — you're ahead of them."
        case .done(.failed(let reason)): return "Check failed: \(reason)"
        }
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updateState {
        case .checking:
            ProgressView().controlSize(.small)
        case .done(.updateAvailable(_, let url)):
            Link("View release", destination: url)
        default:
            Button("Check for Updates") {
                updateState = .checking
                Task {
                    updateState = .done(await UpdateCheck.check(currentVersion: AppInfo.version))
                }
            }
        }
    }
}

// MARK: - Building blocks

/// The grouped-card shape: rows share one rounded surface — the System
/// Settings look, from the facelift's tokens. Rows separate themselves: every
/// row after the first draws a hairline above, which is simpler than counting
/// children and gives the same result.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.cardFill))
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    /// Set on every row after a card's first; draws the separating hairline.
    var divided = false
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            if divided {
                Rectangle()
                    .fill(Theme.Palette.cardSeparator)
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
