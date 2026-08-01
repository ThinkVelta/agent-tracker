import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: SessionStore
    /// Closes the hosting popover; row clicks invoke it after focusing the
    /// terminal so the popover doesn't float over the window it just raised.
    var dismiss: () -> Void = {}

    @State private var searchText = ""

    private var filteredSessions: [AgentSession] {
        var sessions = store.sessions
        if let filter = store.selectedFilter {
            sessions = sessions.filter { $0.state == filter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.projectName.localizedCaseInsensitiveContains(query)
                || session.providerDisplayName.localizedCaseInsensitiveContains(query)
                || (session.reason?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.cwd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Stays visible while a query is active even if the list shrinks
            // below the cap — otherwise a non-empty filter would keep applying
            // with no visible way to clear it.
            if store.sessions.count > Self.maxVisibleRows || !searchText.isEmpty {
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
        .frame(width: 340)
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

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agent Sessions")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            chip(.needsYou, store.counts.needsYou)
            chip(.running, store.counts.running)
            chip(.idle, store.counts.idle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Clickable state filter: tap a dot to show only that state, tap again to
    /// clear the filter. Backed by the store so menu-bar dot clicks and chips
    /// share one filter.
    private func chip(_ state: SessionState, _ count: Int) -> some View {
        Button {
            store.selectedFilter = (store.selectedFilter == state) ? nil : state
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(state.color.opacity(count == 0 ? 0.35 : 1))
                    .frame(width: 7, height: 7)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? .secondary : .primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    store.selectedFilter == state ? Color.primary.opacity(0.12) : .clear)
            )
            .overlay(
                Capsule().stroke(
                    store.selectedFilter == state ? Color.primary.opacity(0.25) : .clear,
                    lineWidth: 1
                ))
        }
        .buttonStyle(.plain)
        .help("Show only \"\(state.label)\" sessions")
    }

    /// Deliberately NOT a ScrollView: under the previous MenuBarExtra host,
    /// rows inside a ScrollView reserved space but painted blank whenever the
    /// list updated while the window was closed. The NSPopover host may not
    /// share that bug, but the cap plus the dot filters and search field make
    /// scrolling unnecessary, so the always-painting plain VStack stays.
    private static let maxVisibleRows = 14

    /// Shown only when the list overflows: filters by project, provider,
    /// status reason, or path, composing with the dot filter.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter sessions", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var emptyFilterMessage: String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No sessions match \"\(searchText)\""
        }
        if let filter = store.selectedFilter {
            return "No \"\(filter.label)\" sessions"
        }
        return "No agent sessions"
    }

    private var sessionList: some View {
        VStack(spacing: 1) {
            if filteredSessions.isEmpty {
                Text(emptyFilterMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(filteredSessions.prefix(Self.maxVisibleRows)) { session in
                    SessionRow(session: session) {
                        let exactTitle = store.exactWindowTitle(for: session)
                        let outcome = TerminalFocuser.focus(session, exactTitle: exactTitle)
                        // Acknowledge only when the raised window is
                        // identifiably this session's (strictly better match
                        // than every sibling) — a fallback raise can land on
                        // an unrelated window, and silencing the session on
                        // that guess hides a red state the user never saw.
                        if case .focusedWindow(let title) = outcome,
                            TerminalFocuser.isPreferredMatch(
                                windowTitle: title, for: session, exactTitle: exactTitle,
                                among: store.sessions.map {
                                    ($0, store.exactWindowTitle(for: $0))
                                })
                        {
                            store.acknowledge(session)
                        }
                        dismiss()
                    }
                }
                if filteredSessions.count > Self.maxVisibleRows {
                    let hidden = filteredSessions.count - Self.maxVisibleRows
                    Text("+\(hidden) more — use the dot filters or search to narrow down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
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
    // one) with a 30s timer as safety net — a manual button implied staleness
    // that doesn't exist, and it never covered the codex scanner anyway.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SessionRow: View {
    let session: AgentSession
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(session.providerDisplayName)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                    Text(session.reason ?? session.state.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(relativeTime)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.cwd ?? "")
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
