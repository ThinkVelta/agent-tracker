import SwiftUI

/// What the row's editor is holding before it is committed. Separate from the
/// stored record so closing the editor without arming changes nothing.
struct ContinueDraft: Equatable {
    var message: String = ContinueScheduler.defaultMessage
    var repeats = false
    var sendsOnWake = true
    /// The moment a clock-anchored schedule fires at. Ignored whenever a reset
    /// anchors the row instead. An hour out by default: near enough to be a
    /// plausible "after this meeting", far enough that a stray Return cannot
    /// schedule something for thirty seconds from now.
    var fireAt: Date = Date().addingTimeInterval(3600)

    init() {}

    init(schedule: ScheduledContinue?) {
        guard let schedule else { return }
        message = schedule.message
        repeats = schedule.repeats
        sendsOnWake = schedule.sendsOnWake
        if schedule.isClockAnchored { fireAt = schedule.armedForResetAt }
    }
}

/// The moments people actually ask for, so the date field is for the exact
/// minute rather than for every scheduling decision.
enum ContinuePreset: CaseIterable {
    case inAnHour
    case inThreeHours
    case tomorrowMorning

    var label: String {
        switch self {
        case .inAnHour: return "+1h"
        case .inThreeHours: return "+3h"
        case .tomorrowMorning: return "9:00 tomorrow"
        }
    }

    /// `now` is a parameter rather than a `Date()` inside, so the arithmetic is
    /// testable and every preset in one click resolves against one instant.
    func moment(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .inAnHour:
            return now.addingTimeInterval(3600)
        case .inThreeHours:
            return now.addingTimeInterval(3 * 3600)
        case .tomorrowMorning:
            // Counted from midnight, not from `now`: `bySettingHour` searches
            // forward, so setting 9:00 on a moment already past 9:00 would land
            // on the day after the one meant.
            let midnight =
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: midnight) ?? midnight
        }
    }
}

/// The inline arming panel that opens under a row.
///
/// Inline rather than a popover: the dropdown is a `.nonactivatingPanel`, and
/// the row list already re-anchors the panel through `onSizeChange` when its
/// height changes, so growing the row is a mechanism that already works. A
/// popover inside a non-activating panel is not.
///
/// Laid out as a small form: a fixed label column with every control sharing
/// one left edge, in the dropdown's own tile language rather than in stock
/// AppKit chrome, so the panel reads as part of the list it grew out of.
struct ContinueEditor: View {
    @Binding var draft: ContinueDraft
    /// The provider's own reset, when this session is the one waiting on a
    /// usage limit. Present, it anchors the schedule; absent, the row is still
    /// armable and the moment comes from the picker below.
    let resetsAt: Date?
    /// Whether the schedule being edited (or created) anchors to a reset.
    /// Decided by the row, which knows both the limit state and what is
    /// already armed — the editor just renders it.
    let usesReset: Bool
    let isArmed: Bool
    let unavailableReason: String?
    /// Set when this session runs in a mode that acts without asking.
    var unattended: String?
    /// The last thing that happened to this session's schedule, if anything has.
    /// A feature that acts unwatched owes a receipt, and this is where someone
    /// looks for it — the log is for afterwards, not for reassurance now.
    var lastReceipt: ContinueReceipt?
    let onArm: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    /// Claimed explicitly rather than left to AppKit's first-key-view walk,
    /// which the preset buttons beside the field would otherwise be in the
    /// running for. Typing on open has to replace the default message.
    @FocusState private var messageFocused: Bool

    /// Wide enough for "Message" at the panel's own type size, which is the
    /// longest label the form has.
    private static let labelColumn: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(Theme.Typography.sessionMeta)
                .fixedSize(horizontal: false, vertical: true)

            if let unattended {
                // Informed consent, which is what this decision owes the user
                // instead of a refusal: a bypass-mode session can act unwatched,
                // and that is true whether the user types "Continue" or the app
                // does. The only thing auto-resume changes is who is present.
                Label(unattended, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.sessionMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if unavailableReason == nil { form }

            if let lastReceipt {
                Text(lastReceipt.summary)
                    .font(Theme.Typography.sessionMeta)
                    .foregroundStyle(lastReceipt.outcome == .sent ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(Theme.Typography.sessionMeta)
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding + 4)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.rowCornerRadius)
                .fill(Theme.Palette.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.rowCornerRadius)
                .strokeBorder(Theme.Palette.hairline)
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Message") { messageField }
            if usesReset {
                // Repeating only exists against resets: a clock moment has no
                // observable next occurrence to re-arm against.
                field(nil) { Toggle("Repeat at every reset", isOn: $draft.repeats) }
            } else {
                field("Time") { timePicker }
                field(nil) { presets }
            }
            field(nil) { Toggle("Send on wake if the Mac was asleep", isOn: $draft.sendsOnWake) }
        }
    }

    /// One line of the form: a fixed right-aligned label column, then the
    /// control. The column is the whole point — it is what gives the field, the
    /// picker and both checkboxes a single left edge.
    private func field<Control: View>(
        _ label: String?, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Text(label ?? "")
                .foregroundStyle(.secondary)
                .frame(width: Self.labelColumn, alignment: .trailing)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Styled as the dropdown's search field rather than `.roundedBorder`: the
    /// default message is right almost every time, so the input people change
    /// least should not be the brightest thing in the panel.
    private var messageField: some View {
        TextField(ContinueScheduler.defaultMessage, text: $draft.message)
            .textFieldStyle(.plain)
            .focused($messageFocused)
            .padding(.horizontal, 7)
            .frame(height: Theme.Metrics.searchFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.searchCornerRadius)
                    .fill(Theme.Palette.tileRest)
            )
            .onAppear { messageFocused = true }
    }

    /// Time only while the moment is today, which is most of them. The date
    /// arrives with the first moment that needs one, and from then on the field
    /// can reach any day.
    private var timePicker: some View {
        DatePicker(
            "Time", selection: $draft.fireAt, in: Date()...,
            // From-now only: the range is what makes a moment in the past
            // unrepresentable, rather than a check at arm time.
            displayedComponents: Calendar.current.isDateInToday(draft.fireAt)
                ? [.hourAndMinute] : [.date, .hourAndMinute]
        )
        .datePickerStyle(.field)
        .labelsHidden()
    }

    private var presets: some View {
        HStack(spacing: 4) {
            ForEach(ContinuePreset.allCases, id: \.self) { preset in
                PresetChip(label: preset.label) { draft.fireAt = preset.moment(from: Date()) }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if isArmed {
                Button("Cancel it", action: onCancel)
            }
            Spacer(minLength: 0)
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            if unavailableReason == nil {
                Button(isArmed ? "Update" : "Schedule", action: onArm)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var headline: String {
        Self.headline(
            unavailableReason: unavailableReason, usesReset: usesReset, resetsAt: resetsAt,
            fireAt: draft.fireAt, now: Date())
    }

    /// The one line above the form: when this session gets its message, resolved
    /// live as the picker moves. Static so the wording is testable without a view.
    static func headline(
        unavailableReason: String?, usesReset: Bool, resetsAt: Date?, fireAt: Date, now: Date
    ) -> String {
        if let unavailableReason { return unavailableReason }
        if !usesReset { return "Sends \(describe(fireAt, relativeTo: now))" }
        guard let resetsAt else {
            // A repeating schedule between firings: there is genuinely no next
            // moment until a later reset is observed, and inventing one would
            // send into a session that is still blocked.
            return "Sends when the limit next resets"
        }
        return "Sends when the limit resets \(describe(resetsAt, relativeTo: now))"
    }

    /// A moment the way this panel says it: the time alone today, a weekday
    /// within the week, a date beyond it. Always a phrase that reads after
    /// "Sends", so the headline stays one sentence in every state.
    static func describe(_ moment: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        let clock = DateFormatter()
        clock.timeStyle = .short
        clock.dateStyle = .none
        let time = clock.string(from: moment)
        if calendar.isDate(moment, inSameDayAs: now) { return "at \(time)" }
        let day = DateFormatter()
        // Six days, not seven: a weekday name a full week out names today.
        let weekOut = calendar.date(byAdding: .day, value: 6, to: now) ?? now
        day.setLocalizedDateFormatFromTemplate(moment < weekOut ? "EEE" : "dMMM")
        return "\(day.string(from: moment)) at \(time)"
    }
}

/// A preset in the dropdown's own tile language, so the times that need no
/// picker at all do not add three more push buttons to the panel.
private struct PresetChip: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.searchCornerRadius)
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .padding(.horizontal, 7)
                .frame(height: Theme.Metrics.searchFieldHeight - 4)
                .background(shape.fill(hovering ? Theme.Palette.tileHover : Theme.Palette.tileRest))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Every state of the editor in one column for `--render-preview --view editor`,
/// which is the only way to look at states a screenshot cannot reach.
struct ContinueEditorPreviewStack: View {
    /// Pinned to mid-morning rather than taken from the clock, so the "today"
    /// half of the picker does not disappear from the render whenever the
    /// author happens to be working late.
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            state("clock, unarmed", draft: clock)
            state("clock, armed", draft: clock, isArmed: true)
            state("clock, a later day", draft: laterDay)
            state("reset, unarmed", draft: clock, usesReset: true, resetsAt: reset)
            state("reset, armed, repeating", draft: repeating, usesReset: true, isArmed: true)
            state("unavailable", draft: clock, reason: "Turn on scheduled continues in Settings")
            state("unattended", draft: clock, unattended: warning)
            state("receipt, sent", draft: clock, isArmed: true, receipt: receipt(.sent))
            state("receipt, failed", draft: clock, isArmed: true, receipt: receipt(.failed))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(width: Theme.Metrics.popoverWidth)
    }

    private var clock: ContinueDraft {
        var draft = ContinueDraft()
        draft.fireAt = now.addingTimeInterval(3600)
        return draft
    }

    private var laterDay: ContinueDraft {
        var draft = ContinueDraft()
        draft.fireAt = ContinuePreset.tomorrowMorning.moment(from: now)
        return draft
    }

    private var repeating: ContinueDraft {
        var draft = clock
        draft.repeats = true
        return draft
    }

    private var reset: Date { now.addingTimeInterval(2 * 3600) }

    private var warning: String {
        "This session runs without asking permission (bypassPermissions). Once resumed it can "
            + "keep working, including running commands, while nobody is watching."
    }

    private func receipt(_ outcome: ContinueReceipt.Outcome) -> ContinueReceipt {
        ContinueReceipt(
            sessionId: "preview", project: "demo", message: "Continue", at: now,
            outcome: outcome, detail: "No window matched that title, so nothing was typed.")
    }

    private func state(
        _ caption: String, draft: ContinueDraft, usesReset: Bool = false, isArmed: Bool = false,
        resetsAt: Date? = nil, reason: String? = nil, unattended: String? = nil,
        receipt: ContinueReceipt? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.tertiary)
            ContinueEditor(
                draft: .constant(draft), resetsAt: resetsAt, usesReset: usesReset,
                isArmed: isArmed, unavailableReason: reason, unattended: unattended,
                lastReceipt: receipt, onArm: {}, onCancel: {}, onDismiss: {})
        }
    }
}
