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

/// The inline arming panel that opens under a row.
///
/// Inline rather than a popover: the dropdown is a `.nonactivatingPanel`, and
/// the row list already re-anchors the panel through `onSizeChange` when its
/// height changes, so growing the row is a mechanism that already works. A
/// popover inside a non-activating panel is not.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(Theme.Typography.sessionMeta)
                .foregroundStyle(.secondary)
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

            if unavailableReason == nil {
                TextField(ContinueScheduler.defaultMessage, text: $draft.message)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.sessionMeta)

                if !usesReset {
                    // From-now only: the range is what makes a moment in the
                    // past unrepresentable, rather than a check at arm time.
                    DatePicker(
                        "Send at", selection: $draft.fireAt, in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                }

                if usesReset {
                    // Repeating only exists against resets: a clock moment has
                    // no observable next occurrence to re-arm against.
                    Toggle("Do it again at the next reset too", isOn: $draft.repeats)
                }
                Toggle("Send on wake if the Mac slept through it", isOn: $draft.sendsOnWake)
            }

            if let lastReceipt {
                Text(lastReceipt.summary)
                    .font(Theme.Typography.sessionMeta)
                    .foregroundStyle(lastReceipt.outcome == .sent ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if isArmed {
                    Button("Cancel it", action: onCancel)
                }
                Spacer(minLength: 0)
                Button("Close", action: onDismiss)
                if unavailableReason == nil {
                    Button(isArmed ? "Update" : "Schedule", action: onArm)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(Theme.Typography.sessionMeta)
        .padding(.horizontal, Theme.Metrics.rowHorizontalPadding + 4)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.rowCornerRadius)
                .fill(Theme.Palette.rowHover)
        )
    }

    private var headline: String {
        if let unavailableReason { return unavailableReason }
        if !usesReset {
            return isArmed
                ? "Sends at \(Self.describe(draft.fireAt))"
                : "Type into this session's terminal at a time you pick"
        }
        guard let resetsAt else {
            // A repeating schedule between firings: there is genuinely no next
            // moment until a later reset is observed, and inventing one would
            // send into a session that is still blocked.
            return "Armed — waiting for the next reset to be reported"
        }
        let moment = Self.describe(resetsAt)
        return isArmed ? "Sends at \(moment)" : "Send when the limit resets at \(moment)"
    }

    private static func describe(_ moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(moment) ? .none : .medium
        return formatter.string(from: moment)
    }
}
