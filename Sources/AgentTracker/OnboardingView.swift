import SwiftUI

/// The first-run window: one screen, not a wizard. Hero, one-line value
/// proposition, the three decisions that matter (permission, hooks, login),
/// one accent button. Any dismissal counts as completed — it can never nag
/// twice (the completion flag is set by the AppDelegate on window close).
struct OnboardingView: View {
    /// Closes the hosting window (which marks onboarding completed).
    var dismiss: () -> Void = {}

    @State private var accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
    @State private var claudeInstalled = HookSetup.claudeHookInstalled()
    @State private var codexInstalled = HookSetup.codexHookInstalled()
    @State private var hookPhase: HookPhase = .idle
    @State private var launchAtLogin = LoginItem.isEnabled

    private enum HookPhase: Equatable {
        case idle
        /// Waiting for the explicit go-ahead; lists exactly what will change.
        case confirming
        case running
        case failed(String)
        /// Installed, but not yet working. Codex runs a hook only once the user
        /// has accepted its own review prompt, and nothing tells them that: the
        /// installer succeeded, the checkmark is green, and `codex exec` skips
        /// untrusted hooks silently. Without this the honest outcome of
        /// onboarding is a Codex that reports nothing and no reason why.
        case actionNeeded(String)
    }

    private let agents = Onboarding.installableAgents(
        Onboarding.Environment(
            claudePresent: HookSetup.claudePresent(),
            codexPresent: HookSetup.codexPresent()))

    /// Live status: the user grants Accessibility in System Settings, not in
    /// this window, so the checkmark has to notice by itself.
    private let statusTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var hooksInstalled: Bool {
        agents.allSatisfy { agent in
            switch agent {
            case .claude: return claudeInstalled
            case .codex: return codexInstalled
            }
        } && !agents.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 8) {
                accessibilityRow
                hooksRow
                loginRow
            }
            .padding(.horizontal, 20)
            footer
        }
        .frame(width: 460)
        .onReceive(statusTick) { _ in
            accessibilityGranted = TerminalFocuser.hasAccessibilityPermission
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(.red).frame(width: 16, height: 16)
                Circle().fill(.green).frame(width: 16, height: 16)
                Circle().fill(.gray).frame(width: 16, height: 16)
            }
            .padding(.top, 28)
            Text("Welcome to AgentTracker")
                .font(.system(size: 19, weight: .bold))
            Text("Every agent session, one glance away — red means it needs you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Setup rows

    private var accessibilityRow: some View {
        setupRow(
            done: accessibilityGranted,
            title: "Allow window switching",
            detail: accessibilityGranted
                ? "Granted — clicking a session will jump straight to its terminal."
                : "Accessibility permission lets a click jump to the session's terminal window."
        ) {
            if !accessibilityGranted {
                Button("Open Settings…") { TerminalFocuser.openAccessibilitySettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var hooksRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupRow(
                done: hooksInstalled,
                title: "Connect your agents",
                detail: hooksDetail
            ) {
                if !hooksInstalled && !agents.isEmpty && hookPhase == .idle {
                    Button("Install…") { hookPhase = .confirming }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if hookPhase == .running { ProgressView().controlSize(.small) }
            }
            if hookPhase == .confirming { hookConfirmation }
            if case .failed(let output) = hookPhase { hookFailure(output) }
            if case .actionNeeded(let note) = hookPhase { hookActionNeeded(note) }
        }
    }

    private var hooksDetail: String {
        if agents.isEmpty {
            return "No agent CLIs found (~/.claude, ~/.codex). Install one, then run "
                + "./install.sh from the repo."
        }
        let names = agents.map(\.displayName).joined(separator: " and ")
        return hooksInstalled
            ? "\(names) will report their sessions here."
            : "\(names) detected. Their hooks report session activity to this app."
    }

    /// The explicit consent step: name every file that will be edited, note
    /// the backups, and only act on a second click.
    private var hookConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(agents, id: \.self) { agent in
                Text("\(agent.displayName): adds a hook entry to \(agent.editedConfig)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Each file is backed up first. ./integrations/uninstall.sh reverses everything.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack {
                Button("Install hooks") { Task { await runInstallers() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { hookPhase = .idle }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func hookFailure(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Scrolls rather than truncates: the installers print precise,
            // actionable errors (e.g. which notify setting they refused to
            // clobber), and cutting them off would hide the one line that
            // matters.
            ScrollView {
                Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            Text("Manual fallback: run ./install.sh from the repo.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Succeeded, but the user is not done. Deliberately not styled as an
    /// error — nothing went wrong — and deliberately not dismissible on its
    /// own, since the row above it now shows a green checkmark that would
    /// otherwise be the last word.
    private func hookActionNeeded(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("One step left")
                .font(.system(size: 11, weight: .semibold))
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func runInstallers() async {
        hookPhase = .running
        var failures: [String] = []
        for agent in agents {
            let outcome = await HookSetup.runInstaller(for: agent)
            if !outcome.succeeded {
                failures.append("\(agent.displayName):\n\(outcome.output)")
            }
        }
        claudeInstalled = HookSetup.claudeHookInstalled()
        codexInstalled = HookSetup.codexHookInstalled()
        if !failures.isEmpty {
            hookPhase = .failed(failures.joined(separator: "\n"))
        } else if HookSetup.codexHooksAwaitTrust(),
            let note = Onboarding.Agent.codex.postInstallAction
        {
            hookPhase = .actionNeeded(note)
        } else {
            hookPhase = .idle
        }
    }

    private var loginRow: some View {
        setupRow(
            done: launchAtLogin,
            title: "Start at login",
            detail: LoginItem.isSupported
                ? "Keep the menu bar dots around without thinking about it."
                : "Needs the installed app — run `make install`, then enable this from the app "
                    + "in /Applications."
        ) {
            Toggle("", isOn: loginBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!LoginItem.isSupported)
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                try? LoginItem.setEnabled(wanted)
                // Reflect reality, not intent: re-read the actual state so the
                // switch can never show "on" while unbound.
                launchAtLogin = LoginItem.isEnabled
            })
    }

    private func setupRow<Accessory: View>(
        done: Bool,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(done ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Palette.tileRest)
        )
    }

    private var footer: some View {
        Button(action: dismiss) {
            Text(accessibilityGranted || hooksInstalled ? "Done" : "Skip for now")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 26)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .padding(.vertical, 20)
    }
}
