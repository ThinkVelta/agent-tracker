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
    @ObservedObject private var updates = UpdateScheduler.shared
    @Environment(\.openSettings) private var openSettings

    @State private var searchText = ""
    /// Explicit collapse choices, which override the automatic idle folding
    /// below. Absent means "whatever the list thinks is sensible".
    @State private var sectionOverrides: [String: Bool] = [:]

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var filteredSessions: [AgentSession] {
        var sessions = store.sessions
        if let filter = store.selectedFilter {
            sessions = sessions.filter { $0.state == filter }
        }
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayName.localizedCaseInsensitiveContains(query)
                // Shown only on ambiguous rows, but findable on every one: this
                // is the name Claude Code shows in the session's own terminal,
                // so a user may well type it whether the row wears it or not.
                || (session.registryName?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.reason?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.primaryDirectory?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Derived from the rows that will be on screen, not from every session:
    /// a row cannot be confused with one the filter has already removed.
    private var rowTitles: [String: String] {
        SessionNaming.titles(for: filteredSessions)
    }

    /// Pinned rows, in the store's own order. Held out of the state sections
    /// rather than duplicated into a strip above them: a row in two places is a
    /// row you can click twice and acknowledge once.
    private var pinnedRows: [AgentSession] {
        filteredSessions.filter(\.isPinned)
    }

    /// Pinned rows spend from the same budget as everything else, and are
    /// capped by it. Subtracting their count from the sections' budget without
    /// capping them is not "spending from the budget", it is exempting them
    /// from it: pin twenty and twenty draw while the sections get nothing.
    private var visiblePinnedRows: [AgentSession] {
        Array(pinnedRows.prefix(Theme.Metrics.maxVisibleRows))
    }

    private var sections: [SessionSections.Section] {
        // A filter or search always expands idle — hiding matches would lie
        // about how many things matched — and the preference decides the rest.
        let folding = preferences.idleFolding
        let narrowing = store.selectedFilter != nil || !query.isEmpty
        return SessionSections.build(
            from: filteredSessions.filter { !$0.isPinned },
            grouping: preferences.grouping,
            overrides: SessionSections.overridesForNarrowing(
                sectionOverrides, narrowing: narrowing),
            autoCollapseIdle: !narrowing && folding != .never,
            budget: max(0, Theme.Metrics.maxVisibleRows - visiblePinnedRows.count),
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
            if let release = updates.available {
                UpdateBanner(release: release) { openSettings() }
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
                if !visiblePinnedRows.isEmpty {
                    // The header counts every pin, not the drawn ones, so the
                    // number matches what the user pinned.
                    PinnedHeader(count: pinnedRows.count)
                    ForEach(visiblePinnedRows) { session in
                        row(for: session)
                    }
                }
                ForEach(sections) { section in
                    sectionHeader(section)
                    ForEach(section.rows) { session in
                        row(for: session)
                    }
                }
                let hidden =
                    (pinnedRows.count - visiblePinnedRows.count)
                    + sections.reduce(0) { $0 + $1.hiddenByBudget }
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
                sectionOverrides[section.id] = !section.isCollapsed
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(section.accent.color)
                    .frame(width: 6, height: 6)
                Text(section.title.uppercased())
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
                ? "Show \(section.title) sessions"
                : "Hide \(section.title) sessions")
    }

    private func row(for session: AgentSession) -> some View {
        SessionRow(
            session: session,
            clockTick: store.clockTick,
            onAcknowledge: { store.acknowledge(session) },
            arming: ContinueScheduler.availability(
                for: session, armableResetBySession: store.armableResetBySession,
                enabled: preferences.scheduledContinues),
            windowTitle: store.exactWindowTitle(for: session),
            title: rowTitles[session.sessionId],
            onSelect: {
                store.focus(session)
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
            Text("Start a Claude Code session,\nor run ./install.sh from the repo.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // No Refresh button: reloads are event-driven (every hook write triggers
    // one) with a periodic safety-net reload (cadence in Settings) — a manual
    // button implied a staleness that does not exist.
    /// Settings far left, quit far right — a routine control and a destructive
    /// one should not be adjacent (user feedback: quit felt misclickable next
    /// to the gear). That is the one rule this bar has always had, and the only
    /// one the quota did not change.
    ///
    /// One bar, not two. Quota lived on its own row above this one and read as
    /// a second footer for the sake of two numbers; the controls, the count and
    /// the quota are all "about the list rather than in it", so they belong on
    /// the same line.
    ///
    /// The count gives up its centred position for it. Centring only looked
    /// deliberate while the row held one thing — with the quota on the left it
    /// would read as approximately-centred, which is worse than plainly
    /// right-aligned. Two groups now: settings and quota at the leading edge,
    /// count and quit at the trailing one.
    ///
    /// A window with no reading simply is not there, so a footer stays a footer
    /// on a machine that has never run the statusline wrapper. An empty strip
    /// would have implied "nothing used" where the truth is "nothing known".
    private var footer: some View {
        HStack(spacing: 8) {
            FooterIconButton(systemName: "gearshape", help: "Settings (⌘,)") {
                // Close the panel first or the settings window opens behind
                // it; activate because an accessory app's windows otherwise
                // appear without focus.
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            ForEach(store.usage) { reading in
                UsageChip(reading: reading)
            }
            Spacer(minLength: 4)
            Text(sessionSummary)
                .font(Theme.Typography.footer)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(1)
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
/// One provider's remaining quota: a label, a bar, a number.
///
/// The bar carries no colour until the number is worth reacting to. A gauge that
/// is amber at 50% teaches people to ignore it, and this sits in a window opened
/// to answer a different question.
/// The pinned group's rule.
///
/// Deliberately without the chevron its neighbours have: a pinned group is what
/// the user asked to keep visible, so offering to hide it is offering to undo
/// the thing they just did. Unpinning is on the row's own menu.
private struct PinnedHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text("PINNED")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            Text("\(count)")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding)
        .frame(height: Theme.Metrics.sectionHeaderHeight)
    }
}

private struct UsageChip: View {
    let reading: UsageReading

    private var tint: Color {
        switch reading.usedPercent {
        case ..<75: return Color.secondary
        case ..<90: return Theme.Palette.warning
        default: return Theme.Palette.critical
        }
    }

    /// A template, not a format: `j` is "hour in whatever convention this user
    /// reads", so a 12-hour locale gets 12-hour output. The rest of the app
    /// already localizes its times (`UsageLimit.reason`), and a tooltip that
    /// disagreed with the row above it would read as a bug.
    private var resetHelp: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDateInToday(reading.resetsAt) ? "jm" : "E jm")
        return "Resets \(formatter.string(from: reading.resetsAt))"
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(reading.windowLabel)
                .font(Theme.Typography.footer)
                .foregroundStyle(.tertiary)
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 34, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: 34 * min(max(reading.usedPercent, 0), 100) / 100, height: 3)
                }
            Text("\(Int(reading.usedPercent.rounded()))%")
                .font(Theme.Typography.footer)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help(resetHelp)
    }
}

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
    /// Whether this row can be armed to resume itself, or why it cannot.
    /// Defaulted so the row keeps its single-argument construction sites.
    var arming: ContinueScheduler.Availability = .unavailable(reason: "")
    /// The session's live terminal window title, which is how a Ghostty surface
    /// is identified at all. Supplied by the parent, which owns the store.
    var windowTitle: String?
    /// What to call this row. Decided by the parent rather than the row,
    /// because whether the project name is ambiguous is a fact about the *list*
    /// — a row cannot see its own siblings. Defaults to the project name so the
    /// row's other construction sites (previews) need no change.
    var title: String?
    let onSelect: () -> Void

    @State private var hovering = false

    /// The trailing control is a SIBLING of the row button, never inside its
    /// label. #28 (`99608db`) removed exactly such a nested control with the
    /// reason written down: a button within a button is unreliable in SwiftUI,
    /// and a click landing on the row action would focus the terminal and
    /// dismiss the panel — which for an arming control would mean arming
    /// something and being thrown out of the list.
    ///
    /// One `contextMenu` with conditional items rather than two branches. The
    /// previous shape attached it only to needs-you rows, and adding a second
    /// branch here would have dropped "Mark as seen" from exactly the rows this
    /// feature targets.
    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .trailing) {
                rowButton
                trailingAffordance
            }
            // Tracked on the whole row, NOT on `rowButton`. The trailing control
            // is a sibling of that button, so with the handler on the button,
            // moving the pointer onto the control un-hovered the row — which hid
            // the control, which put the pointer back over the button, which
            // re-hovered the row. Hover drove hit-testing and hit-testing drove
            // hover, and the pair oscillated at screen refresh rate.
            .onHover { self.hovering = $0 }
            if editing { editorPanel }
            if renaming { renamePanel }
        }
        .contextMenu {
            if session.state == .needsYou {
                // Kept because clicking a row only acknowledges when focus
                // SUCCEEDS: without Accessibility permission every attempt
                // returns `.needsPermission`, so every red row would be stuck
                // with no way out.
                Button("Mark as seen", action: onAcknowledge)
            }
            Button(session.isPinned ? "Unpin" : "Pin to top") { pinned.toggle(session.id) }
            Button(session.isMuted ? "Unmute" : "Mute") { muted.toggle(session.id) }
            if session.terminal?.tmuxPane == nil && windowTitle == nil {
                // The fallback for rows the app cannot type into: no tmux pane
                // reported and no window title known means delivery has nothing
                // to aim at, and reviving the conversation elsewhere is the one
                // path left. Everywhere else the scheduler covers it and this
                // is noise.
                Button("Copy resume command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.resumeCommand, forType: .string)
                }
            }
            Button("Rename…") { renaming = true }
            if armedSchedule != nil {
                Button("Cancel scheduled continue") {
                    continues.disarm(sessionId: session.sessionId)
                }
            }
        }
    }

    // MARK: - Scheduled continues

    /// The shared store, observed directly rather than passed in: `SessionRow`'s
    /// parent has two construction sites and a new required parameter would break
    /// `RenderPreview`.
    @ObservedObject private var continues = ContinueSchedules.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var muted = SessionKeySet.muted
    @ObservedObject private var pinned = SessionKeySet.pinned

    @State private var editing = false
    @State private var draft = ContinueDraft()
    @State private var renaming = false
    /// Read from the transcript when the editor opens, never in a view body —
    /// it is a bounded file read and the body runs on the main actor.
    @State private var unattendedWarning: String?

    private var armedSchedule: ScheduledContinue? {
        continues.schedule(for: session.sessionId)
    }

    /// Always the clock, on every row. The jump arrow that used to fill the
    /// idle slot duplicated the row click and did nothing else; a control that
    /// looks like a button and is not one is worse than the button. Scheduling
    /// is available for any session — the anchor just differs (a usage-limit
    /// reset when this row is the blocked one, a picked time otherwise) — so
    /// the affordance is the same everywhere and clicking it always opens the
    /// editor, including when the feature is off, which is where the editor
    /// says how to turn it on.
    private var trailingAffordance: some View {
        Group {
            if armedSchedule != nil {
                armingButton(icon: "clock.fill", tint: .accentColor, alwaysVisible: true)
            } else {
                // Always visible, not hover-revealed: an affordance the user
                // has to discover by mousing around is one most never find.
                armingButton(icon: "clock", tint: .secondary, alwaysVisible: true)
            }
        }
        .padding(.trailing, Theme.Metrics.rowHorizontalPadding)
    }

    private func armingButton(icon: String, tint: Color, alwaysVisible: Bool) -> some View {
        Button {
            draft = ContinueDraft(schedule: armedSchedule)
            editing.toggle()
            // Read when the panel opens, not in the body: it is a bounded file
            // read, and a mode that acts without asking is worth saying out loud
            // before the user arms it.
            if editing { readPermissionMode() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: Theme.Metrics.rowTrailingControl)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .opacity(alwaysVisible || hovering ? 1 : 0)
        // Live exactly when visible, which is the same expression as the opacity
        // above on purpose. An invisible live control would carve a hole out of
        // the row's own hit area — the other half of what #28 got wrong — and a
        // visible dead one is the defect this rule replaced.
        .allowsHitTesting(alwaysVisible || hovering)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if armedSchedule != nil { return "Edit scheduled continue" }
        // A reason only exists when the feature is off; every other row is
        // schedulable now, reset anchor or not.
        if arming.reason != nil { return "Why this session cannot be scheduled" }
        return "Schedule a continue"
    }

    /// Off the main actor: reading a transcript tail is I/O, and a mode that
    /// acts without asking is worth saying out loud before the user arms it.
    private func readPermissionMode() {
        let sessionId = session.sessionId
        Task {
            let mode = await Task.detached { () -> String? in
                guard
                    let row = SessionStore.loadSessionFromDisk(sessionId: sessionId)
                else {
                    return nil
                }
                // Same order as the delivery gate reads it, so the panel cannot
                // promise one thing and the send decide another.
                return row.transcriptPath.flatMap {
                    ContinueSender.permissionMode(inTranscriptAt: $0)
                } ?? row.permissionMode
            }.value
            unattendedWarning = ContinueDelivery.unattendedWarning(for: mode)
        }
    }

    private var renamePanel: some View {
        RenameEditor(
            sessionId: session.sessionId,
            current: session.registryName,
            // The same fallback arming uses, for the same reason — see the
            // comment on the arming call site. Being stricter here would give
            // rename less reach than a scheduled continue while asking the
            // identical question.
            expectedTitle: windowTitle ?? session.displayName,
            onDismiss: { renaming = false })
    }

    /// Whether the schedule being edited or created anchors to a usage-limit
    /// reset. An armed schedule keeps its own anchor, whichever way the limit
    /// state has moved since: a reset schedule is not converted because the
    /// limit expired, and a clock schedule is not converted because a limit
    /// appeared. Only a new schedule derives its anchor from the row.
    private var anchorsToReset: Bool {
        if let armedSchedule { return !armedSchedule.isClockAnchored }
        return arming.resetsAt != nil
    }

    private var editorPanel: some View {
        ContinueEditor(
            draft: $draft,
            // `pendingMoment`, not `armedForResetAt`: a settled repeating schedule
            // still holds the moment it last fired for, and the editor would
            // present that past time as a promise. Nil is what makes it say it is
            // waiting for the next reset to be reported. Gated on the anchor,
            // so a clock edit on a row that has since hit a limit shows the
            // picker and clock copy, never reset copy.
            resetsAt: anchorsToReset ? (arming.resetsAt ?? armedSchedule?.pendingMoment) : nil,
            usesReset: anchorsToReset,
            isArmed: armedSchedule != nil,
            // Only when there is nothing armed. An armed schedule knows its own
            // moment, so an armed row whose limit has since expired must still
            // say when it sends rather than "available once this session is
            // waiting on a usage limit".
            unavailableReason: armedSchedule == nil ? arming.reason : nil,
            unattended: unattendedWarning,
            lastReceipt: continues.receipts.first { $0.sessionId == session.sessionId },
            onArm: {
                // `armedForResetAt` here, deliberately not `pendingMoment` as the
                // display above uses. Committing an edit to a settled repeating
                // schedule must keep the record's own moment — `settledThrough`
                // travels with it, so it stays settled and does not fire — where
                // `pendingMoment` would be nil and the edit would be dropped.
                // A clock anchor takes the picker's moment instead, on every
                // edit: that moment is the user's and the draft is where they
                // just expressed it.
                let moment: Date
                if anchorsToReset {
                    guard let kept = arming.resetsAt ?? armedSchedule?.armedForResetAt else {
                        return
                    }
                    moment = kept
                } else {
                    moment = draft.fireAt
                }
                continues.armResolvingPane(
                    ScheduledContinue(
                        sessionId: session.sessionId,
                        message: draft.message,
                        armedForResetAt: moment,
                        repeats: anchorsToReset && draft.repeats,
                        sendsOnWake: draft.sendsOnWake,
                        anchor: anchorsToReset ? .reset : .clock,
                        // Preserved, so editing the text of a schedule that has
                        // already fired cannot make it owe that moment again.
                        settledThrough: armedSchedule?.settledThrough,
                        target: armedSchedule?.target,
                        tmuxTarget: armedSchedule?.tmuxTarget,
                        agent: armedSchedule?.agent),
                    // The window title is how a Ghostty surface is identified
                    // at all, and this is the app's best copy of it.
                    //
                    // Deliberately NOT the row's display title. That can be the
                    // registry name on an ambiguous row, and the registry name
                    // is measurably not what the window is called — the
                    // registry says "agent-tracker-3c" where the window says
                    // "Continue tool development with menu interaction". Using
                    // it here would turn a fallback that can match into one
                    // that provably cannot.
                    expectedTitle: windowTitle ?? session.displayName)
                editing = false
            },
            onCancel: {
                continues.disarm(sessionId: session.sessionId)
                editing = false
            },
            onDismiss: { editing = false })
    }

    private var rowButton: some View {
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
                    Text(title ?? session.displayName)
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

                // Its own slot rather than another clause on the metadata line:
                // that line truncates tail-first, so the one number chosen for
                // being worth interrupting you would be the first thing cut.
                if let pressure = ContextPressure(usedPercent: session.contextUsedPercent) {
                    Text(pressure.label)
                        // Quiet readings are set exactly like the timestamp
                        // beside them, so the row reads as one line until the
                        // number has something to say. Weight arrives with the
                        // colour: colour alone at 11pt over a translucent panel
                        // is not enough to carry a warning.
                        .font(
                            pressure.emphasis == .quiet
                                ? Theme.Typography.timestamp
                                : Theme.Typography.contextReading
                        )
                        .foregroundStyle(contextTint(pressure.emphasis))
                        .help(pressure.help)
                }

                Text(relativeTime)
                    .font(Theme.Typography.timestamp)
                    .foregroundStyle(.tertiary)
                // The slot the trailing control draws into, and the LAST element
                // of the HStack. #28's bug was reserving it before the arrow
                // while the control was trailing-aligned, so the control painted
                // on top of the glyph instead of into the gap left for it.
                Color.clear
                    .frame(width: Theme.Metrics.rowTrailingControl, height: 12)
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
        .accessibilityLabel(
            [
                title ?? session.displayName, metadata,
                ContextPressure(usedPercent: session.contextUsedPercent)?.help,
                session.primaryDirectory,
            ]
            .compactMap { $0 }
            .joined(separator: ", "))
    }

    /// `AnyShapeStyle` so the quiet case can be `.tertiary` — the hierarchical
    /// style the timestamp uses, not a colour approximating it. Matching the
    /// neighbour exactly is the whole point of the quiet state.
    private func contextTint(_ emphasis: ContextPressure.Emphasis) -> AnyShapeStyle {
        switch emphasis {
        case .quiet: return AnyShapeStyle(.tertiary)
        case .warning: return AnyShapeStyle(Theme.Palette.warning)
        case .critical: return AnyShapeStyle(Theme.Palette.critical)
        }
    }

    /// One dimmed line under the name: provider, where it lives, what it is
    /// doing. The location matters — several sessions in one repo otherwise
    /// render as identical rows, which is exactly how the user ends up with
    /// sessions they cannot identify.
    private var metadata: String {
        [
            // First, so truncation cannot eat it. A muted row displays as idle,
            // and without this the row would be quietly lying about a session
            // that is in fact waiting on someone.
            session.isMuted ? "Muted" : nil,
            session.locationContext, session.reason ?? session.state.label,
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
