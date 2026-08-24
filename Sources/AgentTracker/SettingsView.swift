import AppKit
import SwiftUI
import UserNotifications

/// The Settings window: the conventional SwiftUI `Settings` scene with tabs —
/// the surface is small, so the sidebar-window shape (à la Stats) would be
/// chrome without content. Sections are grouped cards in the shape the
/// facelift established: radius 10, whisper fill, hairline-separated rows,
/// title left / control right.
struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.selection) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)
            SessionsSettingsTab()
                .tabItem { Label("Sessions", systemImage: "circle.grid.2x1") }
                .tag(SettingsTab.sessions)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
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
            AdvancedSettingsTab()
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
    /// Whether this app may drive Ghostty. Not derivable from anything on disk —
    /// the only way to know is to ask the Apple Event manager.
    @State private var automationGranted: Bool?
    @State private var automationChecking = false

    private var automationDetail: String {
        switch automationGranted {
        case true:
            return "Granted."
        case false:
            return "Not granted yet, so nothing can be sent."
        case nil:
            return "Ghostty isn't running, so there is nothing to ask about yet."
        }
    }

    /// Deliberately a button rather than something that happens on launch: this is
    /// the one call that may raise a permission dialog, and a dialog belongs to a
    /// moment the user chose. Off the main actor because the check was measured
    /// taking over 100 seconds for a running-but-ungranted target.
    private func checkAutomationPermission() {
        automationChecking = true
        Task {
            let granted = await Task.detached { () -> Bool? in
                guard let pid = GhosttyScripting.runningApplication()?.processIdentifier else {
                    return nil
                }
                if case .success = GhosttyScripting.automationPermission(
                    pid: pid, promptIfNeeded: true)
                {
                    return true
                }
                return false
            }.value
            automationGranted = granted
            automationChecking = false
        }
    }

    /// Status only, and never prompts — opening Settings must not raise a dialog.
    private func refreshAutomationStatus() async {
        automationGranted = await Task.detached { () -> Bool? in
            guard let pid = GhosttyScripting.runningApplication()?.processIdentifier else {
                return nil
            }
            if case .success = GhosttyScripting.automationPermission(pid: pid) { return true }
            return false
        }.value
    }

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
                        : "Needs the installed app; run `make install` first."
                ) {
                    Toggle("", isOn: loginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LoginItem.isSupported)
                }
                SettingsRow(
                    title: "Confirm before quitting",
                    detail: "The panel's power button asks first.",
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
                    detail: "Light or dark for the dropdown and windows."
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
                    title: "Group sessions by",
                    detail: "By state to see who needs you; by project to see what each "
                        + "repo is up to.",
                    divided: true
                ) {
                    Picker("", selection: $preferences.grouping) {
                        ForEach(SessionSections.Grouping.allCases, id: \.self) {
                            Text($0.label)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            // Its own card, and off by default. Everything above changes what the
            // app shows; this is the only switch that lets it act on a session
            // while nobody is watching, so it does not belong grouped with the
            // display preferences.
            SettingsCard {
                SettingsRow(
                    title: "Scheduled continues",
                    detail: "Arm a session that stopped on a usage limit to resume when the "
                        + "window resets. Needs permission to control Ghostty."
                ) {
                    Toggle("", isOn: $preferences.scheduledContinues)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if preferences.scheduledContinues {
                    SettingsRow(
                        title: "Permission to control Ghostty",
                        detail: automationDetail,
                        divided: true
                    ) {
                        // No button once it is granted: there is nothing left to
                        // do, and a live control beside "Granted." reads as an
                        // unfinished step. Re-checking is still possible by
                        // revoking it in System Settings, which puts the button
                        // back.
                        if automationGranted == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            // Disabled ONLY while a check is in flight. `nil`
                            // means "Ghostty isn't running", but it is also the
                            // state before the first check returns — and the
                            // status is read once, so a Ghostty started after
                            // Settings opened would leave the only route to the
                            // grant disabled for the rest of the session. The
                            // click re-checks anyway, and reports plainly if
                            // Ghostty still is not there.
                            Button(automationChecking ? "Checking…" : "Allow…") {
                                checkAutomationPermission()
                            }
                            .disabled(automationChecking)
                        }
                    }
                }
            }
        }
        .padding(20)
        .task { await refreshAutomationStatus() }
        // Ghostty may be launched, quit, or have its permission changed in System
        // Settings while this window sits open, so the status is re-read whenever
        // the app comes forward rather than only once.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refreshAutomationStatus() }
        }
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
                                // Monochrome output is a template — black
                                // pixels awaiting the menu bar's tint — so it
                                // has to be drawn as one here too, or every
                                // row goes invisible in dark mode.
                                Image(nsImage: preview(of: mode))
                                    .renderingMode(
                                        preferences.monochromeIcon ? .template : .original)
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
                SettingsRow(
                    title: "Monochrome",
                    detail: "Take the menu bar's tint like a system icon; the states then "
                        + "read by shape.",
                    divided: true
                ) {
                    Toggle("", isOn: $preferences.monochromeIcon)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            SettingsCard {
                SettingsRow(
                    title: "Pulse when a session needs you",
                    detail: "One brief pulse of the red dot when a session flips to needs-you."
                ) {
                    Toggle("", isOn: $preferences.attentionCue)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
        .padding(20)
    }

    /// Every row previews the mode it selects in the colors it will actually
    /// draw, so flipping the switch below restyles the whole list.
    private func preview(of mode: StatusIconRenderer.Mode) -> NSImage {
        StatusIconRenderer.render(
            for: Self.sampleCounts, mode: mode, monochrome: preferences.monochromeIcon
        ).image
    }
}

// MARK: - Sessions

private struct SessionsSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
    /// The raw status, not "allowed or not": the copy below has to tell a
    /// refusal apart from a question that was never answered, and those two
    /// need the user to do different things.
    @State private var notificationStatus: UNAuthorizationStatus?

    /// The user grants this in System Settings, not here, so the row has to
    /// notice by itself.
    private let statusTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Flipping the switch on is the moment to ask, for the same reason the
    /// Automation grant is asked for by a button: a permission dialog belongs
    /// to a click the user made.
    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { preferences.notifyNeedsYou },
            set: { wanted in
                preferences.notifyNeedsYou = wanted
                guard wanted else { return }
                Task {
                    await Notifications.requestAuthorization()
                    await refreshNotificationStatus()
                }
            })
    }

    private var notificationDetail: String {
        guard Notifications.isAvailable else {
            return "Needs the installed app."
        }
        if preferences.notifyNeedsYou {
            switch notificationStatus {
            case .denied:
                return "Turned off in System Settings \u{203A} Notifications."
            case .notDetermined:
                return "macOS has not been asked yet; switch this off and on again to raise "
                    + "the prompt."
            default:
                break
            }
        }
        return "A banner when a session flips to needs-you; clicking it jumps to that terminal."
    }

    /// Only asked while the switch is on: it is a cross-process call, it runs
    /// on the same two-second tick as the Accessibility check, and the copy
    /// above has nothing to say about the answer when nobody wants banners.
    private func refreshNotificationStatus() async {
        guard preferences.notifyNeedsYou else { return }
        notificationStatus = await Notifications.authorizationStatus()
    }

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard {
                // Sits directly above auto-acknowledge because it GATES it:
                // without this permission the app cannot see which terminal
                // window is focused, so visiting a session never clears its
                // red state. Burying that dependency under "About" is what
                // made it invisible.
                SettingsRow(
                    title: "Accessibility permission",
                    detail: accessibilityGranted
                        ? "Granted, so click-to-focus and auto-acknowledge work."
                        : "Not granted, so click-to-focus and auto-acknowledge cannot work."
                ) {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings…") { TerminalFocuser.openAccessibilitySettings() }
                    }
                }
                SettingsRow(
                    title: "Auto-acknowledge after",
                    detail: "Visiting a session's terminal yourself clears its red state "
                        + "after this long.",
                    divided: true
                ) {
                    Picker("", selection: $preferences.autoAckDwell) {
                        ForEach(Preferences.dwellOptions, id: \.seconds) { option in
                            Text(option.label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                SettingsRow(
                    title: "Background check every",
                    detail: "Sweeps for sessions that ended silently. Changes still appear "
                        + "instantly.",
                    divided: true
                ) {
                    Picker("", selection: $preferences.refreshInterval) {
                        ForEach(Preferences.refreshOptions, id: \.seconds) { option in
                            Text(option.label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            SettingsCard {
                SettingsRow(
                    title: "Notify when a session needs you",
                    detail: notificationDetail
                ) {
                    Toggle("", isOn: notifyBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!Notifications.isAvailable)
                }
            }
        }
        .padding(20)
        .task { await refreshNotificationStatus() }
        .onReceive(statusTick) { _ in
            accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
            // Notifications can be switched off for this app in System
            // Settings while this window sits open, and the switch above would
            // then be promising something that cannot happen.
            Task { await refreshNotificationStatus() }
        }
        .onAppear { accessibilityGranted = TerminalFocuser.hasAccessibilityPermission }
    }
}

// MARK: - Advanced

/// Troubleshooting and removal — technical, occasionally destructive, and
/// deliberately not mixed in with the app's identity page.
private struct AdvancedSettingsTab: View {
    @State private var confirmingUninstall = false
    @State private var uninstallState: UninstallState = .idle

    private enum UninstallState: Equatable {
        case idle
        case working
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard {
                SettingsRow(
                    title: "Diagnostics",
                    detail: "A local log of what the app did, for bug reports."
                ) {
                    Button("Show Log") {
                        let log = DebugLog.shared.fileURL
                        // The directory may not exist before the first trace
                        // lands; opening a missing folder is a silent no-op.
                        try? FileManager.default.createDirectory(
                            at: log.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: log.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([log])
                        } else {
                            NSWorkspace.shared.open(log.deletingLastPathComponent())
                        }
                    }
                }
                SettingsRow(
                    title: "Uninstall",
                    detail: uninstallDetail,
                    divided: true
                ) {
                    if uninstallState == .working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Uninstall…") { confirmingUninstall = true }
                            .confirmationDialog(
                                "Uninstall AgentTracker?",
                                isPresented: $confirmingUninstall
                            ) {
                                Button("Uninstall", role: .destructive) {
                                    uninstallState = .working
                                    Task {
                                        switch await Uninstaller.run() {
                                        case .done:
                                            NSApp.terminate(nil)
                                        case .failed(let reason):
                                            uninstallState = .failed(reason)
                                        }
                                    }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text(
                                    "Unhooks Claude Code, restores your statusline, removes "
                                        + "the login item, and removes the app. Session data "
                                        + "in ~/.agent-tracker stays.")
                            }
                    }
                }
            }
        }
        .padding(20)
    }

    private var uninstallDetail: String {
        switch uninstallState {
        case .idle:
            return "Removes the app and everything it set up. Session data stays."
        case .working:
            return "Uninstalling…"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - About

/// The app's identity page: what this is, whose it is, how to reach it —
/// plus updates, which live here because the version they act on is the line
/// above them.
private struct AboutSettingsTab: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var updateState: UpdateState = .idle
    /// Read once per appearance rather than per render: it stats the Caskroom.
    @State private var installSource: InstallSource = .development

    private enum UpdateState: Equatable {
        case idle
        case checking
        case done(UpdateCheck.Outcome)
        case installing
        case installFailed(String)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            SettingsCard {
                SettingsRow(title: "Updates", detail: updateDetail) {
                    updateAccessory
                }
                SettingsRow(
                    title: "Check automatically",
                    detail: "Once at launch and daily. Nothing installs by itself.",
                    divided: true
                ) {
                    Toggle("", isOn: $preferences.updateChecksAutomatically)
                        .labelsHidden()
                }
                if installSource == .direct {
                    SettingsRow(
                        title: "Install automatically",
                        detail: "Installs what the launch check finds, then relaunches. "
                            + "Updates found later only notify.",
                        divided: true
                    ) {
                        Toggle("", isOn: $preferences.updateInstallsAutomatically)
                            .labelsHidden()
                            .disabled(!preferences.updateChecksAutomatically)
                    }
                }
            }
            .onAppear { installSource = InstallSource.current }
            credits
        }
        .padding(20)
    }

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                Circle().fill(.red).frame(width: 14, height: 14)
                Circle().fill(.green).frame(width: 14, height: 14)
                Circle().fill(.gray).frame(width: 14, height: 14)
            }
            .padding(.bottom, 2)
            Text("AgentTracker")
                .font(.system(size: 17, weight: .bold))
            Text("Every agent session, one glance away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(versionLine)
                .font(Theme.Typography.footer)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
    }

    private var credits: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text("Made by")
                    .foregroundStyle(.secondary)
                Link("Velta", destination: URL(string: "https://thinkvelta.ai")!)
            }
            .font(.system(size: 11))
            HStack(spacing: 5) {
                Link(
                    "Source",
                    destination: URL(string: "https://github.com/ThinkVelta/agent-tracker")!)
                Text("·").foregroundStyle(.tertiary)
                Link(
                    "Report an issue",
                    destination: URL(
                        string: "https://github.com/ThinkVelta/agent-tracker/issues")!)
                Text("·").foregroundStyle(.tertiary)
                Link(
                    "MIT License",
                    destination: URL(
                        string:
                            "https://github.com/ThinkVelta/agent-tracker/blob/main/LICENSE")!)
            }
            .font(.system(size: 11))
        }
    }

    private var versionLine: String {
        guard AppInfo.isBundled else { return "development build (swift run)" }
        let build = AppInfo.build.map { " (\($0))" } ?? ""
        return "Version \(AppInfo.version)\(build)"
    }

    private var updateDetail: String {
        switch updateState {
        case .idle: return "Checks the GitHub releases page."
        case .checking: return "Checking…"
        case .done(.upToDate): return "You're on the latest release."
        case .done(.updateAvailable(let release)):
            switch installSource {
            case .homebrew:
                return "\(release.tag) is available. Homebrew installs it and the app relaunches."
            case .direct:
                return release.zip == nil
                    ? "\(release.tag) is available."
                    : "\(release.tag) is available. Installing relaunches the app."
            case .development:
                return "\(release.tag) is available."
            }
        case .done(.noReleases): return "No releases published yet; you're ahead of them."
        case .done(.failed(let reason)): return "Check failed: \(reason)"
        case .installing:
            return installSource == .homebrew ? "Updating with Homebrew…" : "Downloading…"
        case .installFailed(let reason): return reason
        }
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updateState {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .done(.updateAvailable(let release)):
            if installSource == .direct, release.zip != nil {
                Button("Install Update") {
                    updateState = .installing
                    Task {
                        switch await Updater.downloadAndInstall(release) {
                        case .installed:
                            Updater.relaunch()
                        case .failed(let reason):
                            updateState = .installFailed(reason)
                        }
                    }
                }
            } else if installSource == .homebrew {
                Button("Update") {
                    updateState = .installing
                    Task {
                        switch await Updater.upgradeViaHomebrew() {
                        case .installed:
                            Updater.relaunch()
                        case .failed(let reason):
                            updateState = .installFailed(reason)
                        }
                    }
                }
            } else {
                Link("View release", destination: release.page)
            }
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
