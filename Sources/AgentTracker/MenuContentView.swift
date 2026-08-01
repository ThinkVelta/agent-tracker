import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: SessionStore
    /// When set, the list shows only sessions in this state (dot-chip filter).
    @State private var filter: SessionState?

    private var filteredSessions: [AgentSession] {
        guard let filter else { return store.sessions }
        return store.sessions.filter { $0.state == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
    /// clear the filter.
    private func chip(_ state: SessionState, _ count: Int) -> some View {
        Button {
            filter = (filter == state) ? nil : state
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
            .background(Capsule().fill(filter == state ? Color.primary.opacity(0.12) : .clear))
            .overlay(Capsule().stroke(
                filter == state ? Color.primary.opacity(0.25) : .clear, lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
        .help("Show only \"\(state.label)\" sessions")
    }

    private var sessionList: some View {
        ScrollView {
            // Eager VStack on purpose: LazyVStack fails to lay out inside a
            // MenuBarExtra window when content changes while it is closed
            // (rows render zero-height), and laziness buys nothing at this
            // scale anyway.
            VStack(spacing: 1) {
                if filteredSessions.isEmpty, let filter {
                    Text("No \"\(filter.label)\" sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(filteredSessions) { session in
                        SessionRow(session: session) {
                            TerminalFocuser.focus(session)
                            store.acknowledge(session)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 420)
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

    private var footer: some View {
        HStack {
            Button("Refresh") { store.reload() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
