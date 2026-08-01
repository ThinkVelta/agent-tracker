import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: SessionStore
    /// Closes the hosting popover; row clicks invoke it after focusing the
    /// terminal so the popover doesn't float over the window it just raised.
    var dismiss: () -> Void = {}

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
            session.projectName.localizedCaseInsensitiveContains(query)
                || session.providerDisplayName.localizedCaseInsensitiveContains(query)
                || (session.reason?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.cwd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sections: [SessionSections.Section] {
        SessionSections.build(
            from: filteredSessions,
            overrides: sectionOverrides,
            autoCollapseIdle: store.selectedFilter == nil && query.isEmpty
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
                Text("Grant it, then quit and re-run AgentTracker.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                Text(emptyFilterMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
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
        SessionRow(session: session, clockTick: store.clockTick) {
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
        }
    }

    private var emptyFilterMessage: String {
        if !query.isEmpty { return "No sessions match \"\(searchText)\"" }
        if let filter = store.selectedFilter { return "No \"\(filter.label)\" sessions" }
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
    // one) with a 1s timer as safety net — a manual button implied staleness
    // that doesn't exist, and it never covered the codex scanner anyway.
    private var footer: some View {
        HStack(spacing: 0) {
            Text(sessionSummary)
                .font(Theme.Typography.footer)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit AgentTracker")
        }
        .padding(.leading, Theme.Metrics.gutter)
        .padding(.trailing, Theme.Metrics.gutter - 4)
        .padding(.vertical, 5)
    }

    private var sessionSummary: String {
        let total = store.sessions.count
        let noun = total == 1 ? "session" : "sessions"
        guard store.selectedFilter != nil || !query.isEmpty else { return "\(total) \(noun)" }
        return "\(filteredSessions.count) of \(total) \(noun)"
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
    let onSelect: () -> Void

    @State private var hovering = false

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
                    Text(session.projectName)
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
        .onHover { hovering = $0 }
        .help(session.cwd ?? "")
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
