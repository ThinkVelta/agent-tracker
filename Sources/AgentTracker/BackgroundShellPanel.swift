import SwiftUI

/// The inline panel under a row that is red for a background shell: what the
/// shell is, how long it has run, and the button that ends it. Inline for the
/// same reason `RenameEditor` is, and a second step on purpose — the row's
/// control opens this, and only the button here stops anything.
struct BackgroundShellPanel: View {
    let task: BackgroundTask
    let ownerPid: Int?
    let onDismiss: () -> Void

    @State private var outcome: BackgroundShells.Outcome?
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .fixedSize(horizontal: false, vertical: true)
            if let description = task.description {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = task.command {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome {
                Text(outcome.summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
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

    private var headline: String {
        "Background shell hasn't finished in "
            + DurationText.describe(task.age(at: Date()) ?? 0) + "."
    }

    /// Only a shell with a recorded command can be found in the process
    /// table; anything else can be described but not stopped.
    private var canStop: Bool {
        task.type == "shell" && task.command != nil && ownerPid != nil && outcome != .stopped
    }

    private var explanation: String {
        canStop
            ? "Stopping it ends the shell and wakes Claude with the output so far. "
                + "Click the row instead to mark it seen and leave it running."
            : "This one cannot be stopped from here. Click the row to mark it seen."
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            if canStop {
                Button("Stop shell", action: stop)
                    .keyboardShortcut(.defaultAction)
                    .disabled(stopping)
            }
        }
    }

    private func stop() {
        guard let ownerPid else { return }
        stopping = true
        let task = task
        Task {
            let result = await Task.detached {
                BackgroundShells.stop(task, ownerPid: ownerPid)
            }.value
            outcome = result
            stopping = false
        }
    }
}

/// Both shapes of the panel in one column for `--render-preview --view shell`:
/// a shell the app can end, and a task it can only describe.
struct BackgroundShellPanelPreviewStack: View {
    private let firstSeen = Date().addingTimeInterval(-(3 * 3600 + 22 * 60))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackgroundShellPanel(
                task: BackgroundTask(
                    id: "b1", type: "shell", description: "Wait for workflow completion",
                    command: "until [ \"$(grep -c completed journal.jsonl)\" -ge 6 ]; "
                        + "do sleep 15; done",
                    firstSeenAt: firstSeen),
                ownerPid: 1, onDismiss: {})
            BackgroundShellPanel(
                task: BackgroundTask(id: "b2", type: "monitor", firstSeenAt: firstSeen),
                ownerPid: 1, onDismiss: {})
        }
        .padding(4)
        .frame(width: Theme.Metrics.popoverWidth)
    }
}
