import SwiftUI

/// The inline panel for renaming a session.
///
/// Says plainly that it is asking Claude rather than setting a label, because
/// that is what makes the result show up in the terminal tab too — and it is
/// also why the rename can be turned down, which a pure label never could.
struct RenameEditor: View {
    @Binding var name: String
    /// What the row is called now, offered as the field's placeholder so the
    /// user can see what they are replacing.
    let current: String?
    /// The last attempt's outcome, kept visible until the panel closes. A
    /// refusal is the common case for a session the app cannot address, and it
    /// carries the instruction that does work.
    let outcome: String?
    let isSending: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    private var trimmed: String? { SessionRename.sanitize(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask Claude to rename this session. It renames the terminal tab too.")
                .font(Theme.Typography.sessionMeta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(current ?? "session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.sessionMeta)
                .onSubmit(onSubmit)
                .disabled(isSending)

            if let outcome {
                Text(outcome)
                    .font(Theme.Typography.sessionMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(isSending ? "Renaming…" : "Rename", action: onSubmit)
                    // Disabled for empty and for unchanged alike: both would
                    // type a command into a live session to achieve nothing.
                    .disabled(
                        isSending || SessionRename.check(proposed: name, current: current) != nil)
                Button("Close", action: onDismiss)
            }
            .font(Theme.Typography.sessionMeta)
        }
        .padding(8)
    }
}
