import SwiftUI

/// The inline panel for renaming a session, and the delivery behind it.
///
/// Owns its own draft and outcome rather than taking them as bindings, so the
/// row that shows it needs one piece of state (whether it is open) instead of
/// four. The work lives here too, for the same reason: renaming is one concern
/// and this is its file.
///
/// Says plainly that it is asking Claude rather than setting a label, because
/// that is what makes the result show up in the terminal tab too — and it is
/// also why the rename can be turned down, which a pure label never could.
struct RenameEditor: View {
    let sessionId: String
    /// What the row is called now. Seeds the field, since a rename is usually
    /// an edit of what is there rather than a fresh start, and doubles as the
    /// "is this actually a change" comparison.
    let current: String?
    /// How the session's window is found. Supplied by the caller, which owns
    /// the app's best copy of the live window title.
    let expectedTitle: String
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var outcome: String?
    @State private var inFlight = false
    @State private var seeded = false
    /// Held so Close can mean *cancel*, not merely *hide*.
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask Claude to rename this session. It renames the terminal tab too.")
                .font(Theme.Typography.sessionMeta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(current ?? "session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.sessionMeta)
                .onSubmit(submit)
                .disabled(inFlight)

            if let outcome {
                Text(outcome)
                    .font(Theme.Typography.sessionMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(inFlight ? "Renaming…" : "Rename", action: submit)
                    // Disabled for empty and for unchanged alike: both would
                    // type a command into a live session to achieve nothing.
                    .disabled(
                        inFlight || SessionRename.check(proposed: name, current: current) != nil)
                Button("Close", action: close)
            }
            .font(Theme.Typography.sessionMeta)
        }
        .padding(8)
        .onAppear {
            // Once. `onAppear` fires again when the panel is re-shown, and
            // re-seeding would wipe a draft the user is part-way through.
            guard !seeded else { return }
            seeded = true
            name = current ?? ""
        }
    }

    /// Resolves the session's pane and types `/rename` into it.
    ///
    /// Resolution is the slow half — the Automation preflight was measured
    /// taking over 100 seconds for a running-but-ungranted target — so it runs
    /// off the main actor and the button says "Renaming…" meanwhile. The prompt
    /// IS allowed here: the user just asked for this and is looking at the
    /// panel.
    private func submit() {
        guard !inFlight else { return }
        // The same check the button is disabled on. Enter reaches here without
        // going past a disabled button, so the guard has to live in both places
        // or the keyboard quietly gets a path the mouse does not.
        if let refusal = SessionRename.check(proposed: name, current: current) {
            outcome = refusal.reason
            return
        }
        guard let command = SessionRename.command(for: name) else { return }
        inFlight = true
        outcome = nil
        let id = sessionId
        let title = expectedTitle
        work = Task {
            let resolved = await SessionTarget.resolve(
                for: id, expectedTitle: title, promptIfNeeded: true)
            if Task.isCancelled { return }
            // Re-read AFTER resolving, never captured before it. `lastEvent` as
            // the row knows it is a claim about whenever the panel last
            // rendered, and over a hundred seconds of preflight is long enough
            // for the session to have started a turn or opened a dialog.
            let fresh = await Self.freshState(sessionId: id)
            // The last checkpoint that means anything. `deliver` writes and
            // presses Return synchronously, so cancelling after this point
            // cannot unsend — the promise this makes is "nothing is typed",
            // not "the rename is undone", and the window it covers is the slow
            // resolution above, which is where all the waiting actually is.
            if Task.isCancelled { return }
            let result = SessionRename.deliver(
                command: command, resolved: resolved, lastEvent: fresh.lastEvent,
                liveAgent: fresh.agent, ops: .ghostty)
            await MainActor.run {
                inFlight = false
                work = nil
                outcome = result.detail
                // Left open on a refusal so the reason stays readable; closed on
                // success, where the row itself is about to say what happened.
                if result.outcome == .sent { onDismiss() }
            }
        }
    }

    /// Close means cancel. A rename typed into a terminal after the user shut
    /// the panel is a surprise, and the wait it happens during is long enough
    /// that they will have moved on.
    ///
    /// Deliberately NOT also wired to `onDisappear`. The Automation permission
    /// dialog takes focus, which can close the popover this panel lives in — so
    /// cancelling on disappear would cancel the very rename that prompt is
    /// being answered for, breaking the one run where the grant is obtained.
    private func close() {
        work?.cancel()
        work = nil
        // Reset, because this state outlives the panel: leaving it set would
        // reopen with the button stuck saying "Renaming…" forever.
        inFlight = false
        onDismiss()
    }

    /// The two facts delivery must not take on trust, read off disk together.
    private static func freshState(sessionId: String) async -> (
        lastEvent: String?, agent: ProcessIdentity?
    ) {
        await Task.detached {
            let session = SessionStore.loadSessionFromDisk(sessionId: sessionId)
            return (
                session?.lastEvent,
                session?.pid.map { ProcessIdentity.read(pid: Int32($0)) } ?? nil
            )
        }.value
    }
}
