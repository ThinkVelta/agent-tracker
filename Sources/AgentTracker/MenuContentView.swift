import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: SessionStore
    /// Closes the hosting panel; row clicks invoke it after focusing the
    /// terminal so the panel doesn't float over the window it just raised.
    var dismiss: () -> Void = {}
    /// Fired whenever the content's rendered size changes — search narrowing,
    /// section collapse, anything. Geometry-driven rather than enumerating
    /// height-affecting state, so no future state can be forgotten. The
    /// hosting panel re-anchors itself to the menu bar on this signal.
    var onSizeChange: () -> Void = {}

    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.openSettings) private var openSettings

    @State private var searchText = ""
    /// Explicit collapse choices, which override the automatic idle folding
    /// below. Absent means "whatever the list thinks is sensible".
    @State private var sectionOverrides: [SessionState: Bool] = [:]

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var filteredSessions: [AgentSession] {
        var sessions = store.sessions
        if let filter = store.selectedFilter {
            sessions = sessions.filter { $0.state == filter }
        }
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayName.localizedCaseInsensitiveContains(query)
                || session.projectName.localizedCaseInsensitiveContains(query)
                || session.providerDisplayName.localizedCaseInsensitiveContains(query)
                || (session.reason?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.cwd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sections: [SessionSections.Section] {
        // A filter or search always expands idle — hiding matches would lie
        // about how many things matched — and the preference decides the rest.
        let folding = preferences.idleFolding
        let narrowing = store.selectedFilter != nil || !query.isEmpty
        return SessionSections.build(
            from: filteredSessions,
            overrides: SessionSections.overridesForNarrowing(
                sectionOverrides, narrowing: narrowing),
            autoCollapseIdle: !narrowing && folding != .never,
            idleAutoCollapseThreshold: {
                switch folding {
                case .never: return Int.max
                case .always: return 0
                case .past(let threshold): return threshold
                }
            }()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterTiles
            if showsSearch {
                searchField
            }
            Divider()
            if !TerminalFocuser.hasAccessibilityPermission {
                permissionBanner
                Divider()
            }
            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
            Divider()
            footer
        }
        .frame(width: Theme.Metrics.popoverWidth)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizeKey.self) { _ in onSizeChange() }
    }

    private struct ContentSizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    // MARK: - Chrome

    /// Counts and the state filter in one control: the three tiles answer
    /// "does anything need me?" at a glance and are the way to narrow the
    /// list. Backed by the store, so menu bar dot clicks and these stay in
    /// sync — clicking the active one clears the filter.
    private var filterTiles: some View {
        HStack(spacing: 4) {
            ForEach(SessionState.allCases, id: \.self) { state in
                FilterTile(
                    state: state,
                    total: store.counts.count(for: state),
                    isSelected: store.selectedFilter == state
                ) {
                    store.selectedFilter = (store.selectedFilter == state) ? nil : state
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 8)
    }

    /// Shown from a modest number of sessions rather than only on overflow:
    /// the user was surprised to learn the field existed at all.
    private var showsSearch: Bool {
        store.sessions.count >= Theme.Metrics.searchVisibleFromRows || !searchText.isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter sessions", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: Theme.Metrics.searchFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.searchCornerRadius)
                .fill(Theme.Palette.tileRest)
        )
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.bottom, 8)
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text("Click-to-focus needs Accessibility permission")
                    .font(.system(size: 11, weight: .medium))
                // The already-listed case matters: every rebuild of an ad-hoc
                // signed app invalidates its old grant, and toggling the stale
                // entry does nothing — it must be removed and re-added.
                Text(
                    "Grant it in Settings. Already listed? Remove AgentTracker "
                        + "with − and add it again — a rebuilt app invalidates its old grant."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { TerminalFocuser.openAccessibilitySettings() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    /// Deliberately NOT a ScrollView: under the previous MenuBarExtra host,
    /// rows inside a ScrollView reserved space but painted blank whenever the
    /// list updated while the window was closed. The NSPopover host may not
    /// share that bug, but the row cap plus filter tiles, search and
    /// collapsible sections make scrolling unnecessary.
    private var sessionList: some View {
        VStack(spacing: 1) {
            if filteredSessions.isEmpty {
                noMatchesState
            } else {
                let sections = sections
                ForEach(sections) { section in
                    sectionHeader(section)
                    ForEach(section.rows) { session in
                        row(for: session)
                    }
                }
                let hidden = sections.reduce(0) { $0 + $1.hiddenByBudget }
                if hidden > 0 {
                    Text("+\(hidden) more — narrow down with the tiles or search")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    /// A hairline rule carrying the state, its count, and the collapse
    /// affordance. Grouping is what makes a long list readable — the state
    /// filter narrows, sections organize.
    private func sectionHeader(_ section: SessionSections.Section) -> some View {
        Button {
            withAnimation(Theme.Motion.quick) {
                sectionOverrides[section.state] = !section.isCollapsed
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(section.state.color)
                    .frame(width: 6, height: 6)
                Text(section.state.label.uppercased())
                    .font(Theme.Typography.sectionHeader)
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 1)
                Text("\(section.total)")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.Metrics.rowHorizontalPadding)
            .frame(height: Theme.Metrics.sectionHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            section.isCollapsed
                ? "Show \(section.state.label) sessions"
                : "Hide \(section.state.label) sessions")
    }

    private func row(for session: AgentSession) -> some View {
        // Auto-acknowledge only fires when the raised window identifies ONE
        // session beyond doubt, which same-repo siblings never can — so those
        // rows would stay red forever. onAcknowledge is the escape hatch: the
        // user says they've seen it, no guessing required.
        SessionRow(
            session: session,
            clockTick: store.clockTick,
            onAcknowledge: { store.acknowledge(session) },
            onSelect: {
                let exactTitle = store.exactWindowTitle(for: session)
                let outcome = TerminalFocuser.focus(session, exactTitle: exactTitle)
                // Acknowledge only when the raised window is identifiably this
                // session's (strictly better match than every sibling) — a
                // fallback raise can land on an unrelated window, and silencing
                // the session on that guess hides a red state the user never saw.
                if case .focusedWindow(let title) = outcome,
                    TerminalFocuser.isPreferredMatch(
                        windowTitle: title, for: session, exactTitle: exactTitle,
                        among: store.sessions.map { ($0, store.exactWindowTitle(for: $0)) })
                {
                    store.acknowledge(session)
                }
                dismiss()
            })
    }

    /// Sessions exist, but none survived the filter or the query. Centered and
    /// given room like the true empty state — left-aligned in the list's own
    /// padding, it read as a broken list. Offers the way back out, since the
    /// user has narrowed themselves into a dead end.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "circle.dotted" : "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyFilterMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show all \(store.sessions.count) sessions") {
                store.selectedFilter = nil
                searchText = ""
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var emptyFilterMessage: String {
        if !query.isEmpty { return "No sessions match \"\(searchText)\"" }
        if let filter = store.selectedFilter { return filter.emptyListMessage }
        return "No agent sessions"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("No agent sessions")
                .font(.system(size: 12, weight: .medium))
            Text("Start a Claude Code or Codex session,\nor run the installers in integrations/.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // No Refresh button: reloads are event-driven (every hook write triggers
    // one) with a periodic safety-net reload (cadence in Settings) — a manual button implied staleness
    // that doesn't exist, and it never covered the codex scanner anyway.
    /// Settings far left, quit far right — a routine control and a
    /// destructive one should not be adjacent (user feedback: quit felt
    /// misclickable next to the gear). The count sits between symmetric
    /// spacers, so it lands dead center.
    private var footer: some View {
        HStack(spacing: 0) {
            FooterIconButton(systemName: "gearshape", help: "Settings (⌘,)") {
                // Close the panel first or the settings window opens behind
                // it; activate because an accessory app's windows otherwise
                // appear without focus.
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Text(sessionSummary)
                .font(Theme.Typography.footer)
                .foregroundStyle(.tertiary)
            Spacer()
            FooterIconButton(systemName: "power", help: "Quit AgentTracker") {
                requestQuit()
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter - 4)
        .padding(.vertical, 5)
    }

    /// Quit guards against the misclick next to the gear: a confirmation with
    /// a native "don't ask again" suppression checkbox. The checkbox is
    /// honored even on Cancel — it answers "should I ask?", not "do you mean
    /// it this time?" — and Settings › General can re-enable the warning.
    private func requestQuit() {
        guard Preferences.shared.confirmQuit else {
            NSApp.terminate(nil)
            return
        }
        // The alert needs the app frontmost, and the panel floating over a
        // modal looks broken.
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit AgentTracker?"
        alert.informativeText =
            "The menu bar dots disappear and session tracking stops until you launch it again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            Preferences.shared.confirmQuit = false
        }
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        } else {
            // The alert needed activation; on Cancel, hand it back or the
            // user is stranded on an active accessory app with no key window.
            NSApp.deactivate()
        }
    }

    private var sessionSummary: String {
        let total = store.sessions.count
        let noun = total == 1 ? "session" : "sessions"
        guard store.selectedFilter != nil || !query.isEmpty else { return "\(total) \(noun)" }
        return "\(filteredSessions.count) of \(total) \(noun)"
    }
}

/// Footer icon buttons hover-highlight like the rows do — a click target
/// that doesn't react reads as disabled (user feedback: the Quit button).
private struct FooterIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Theme.Palette.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One state's count, doubling as the filter control for that state.
private struct FilterTile: View {
    let state: SessionState
    /// Not named `count`: SwiftLint's empty_count rule rewrites `count == 0`
    /// into `isEmpty`, which an Int does not have.
    let total: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.color.opacity(total == 0 ? Theme.Palette.emptyStateOpacity : 1))
                    .frame(width: 7, height: 7)
                Text("\(total)")
                    .font(Theme.Typography.tileCount)
                    .foregroundStyle(total == 0 ? .secondary : .primary)
                Text(state.label)
                    .font(Theme.Typography.tileLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.tileCornerRadius)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.tileCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "Show all sessions" : "Show only \"\(state.label)\" sessions")
    }

    private var fill: Color {
        if isSelected { return Theme.Palette.tileSelected }
        return hovering ? Theme.Palette.tileHover : Theme.Palette.tileRest
    }
}

struct SessionRow: View {
    let session: AgentSession
    /// Re-renders the relative time on a quiet machine; the value itself is
    /// unused (see `SessionStore.clockTick`).
    var clockTick = 0
    /// Clears a needs-you row without jumping to its terminal.
    var onAcknowledge: () -> Void = {}
    let onSelect: () -> Void

    @State private var hovering = false
    @State private var showsPath = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Theme.Metrics.accentBarWidth / 2)
                    // Idle is the state you are not looking for; its rail
                    // recedes so the reds and greens carry the eye.
                    .fill(
                        session.state.color.opacity(
                            session.state == .idle ? Theme.Palette.idleAccentOpacity : 1)
                    )
                    .frame(width: Theme.Metrics.accentBarWidth)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(Theme.Typography.sessionName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(metadata)
                        .font(Theme.Typography.sessionMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                Text(relativeTime)
                    .font(Theme.Typography.timestamp)
                    .foregroundStyle(.tertiary)
                // Shown on hover for red rows only: auto-acknowledge refuses
                // to fire when two same-repo sessions share a window title, so
                // without this those rows can never be cleared by hand.
                if session.state == .needsYou {
                    Button(action: onAcknowledge) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .help("Mark as seen (clears the red state)")
                }
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Metrics.rowHorizontalPadding)
            .padding(.vertical, Theme.Metrics.rowVerticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.rowCornerRadius))
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.rowCornerRadius)
                    .fill(hovering ? Theme.Palette.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hovering = hovering
            guard hovering else {
                showsPath = false
                return
            }
            // Our own delay rather than .help(): AppKit's tooltip timer is
            // system-owned and takes over a second, which is far too slow for
            // a list you are scanning.
            Task {
                try? await Task.sleep(for: .milliseconds(280))
                if self.hovering { showsPath = true }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsPath, let cwd = session.cwd {
                Text(cwd)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    )
                    .frame(maxWidth: Theme.Metrics.popoverWidth - 32, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: 8, y: 18)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .animation(Theme.Motion.quick, value: showsPath)
        .accessibilityLabel("\(session.displayName), \(metadata), \(session.cwd ?? "")")
    }

    /// One dimmed line under the name: provider, where it lives, what it is
    /// doing. The location matters — several sessions in one repo otherwise
    /// render as identical rows, which is exactly how the user ends up with
    /// sessions they cannot identify.
    private var metadata: String {
        [
            session.providerDisplayName, session.locationContext,
            session.reason ?? session.state.label,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var relativeTime: String {
        guard let since = session.stateChangedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
