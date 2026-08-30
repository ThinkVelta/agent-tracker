# Troubleshooting

## Run this first

```sh
/Applications/AgentTracker.app/Contents/MacOS/AgentTracker --doctor
```

It checks the mechanical half of this page (hooks, the hook script, the
statusline wrapper, session files, permissions, and whether Claude's session
registry still speaks a vocabulary this build knows), and where a finding has a
section here that explains it, prints the link. Read-only: it never writes,
installs or grants anything, and never raises a permission dialog, so it is safe
to run on a machine that is already misbehaving.

**Run it from the project you are having trouble with.** One check walks up from
the working directory looking for a project-level `statusLine`, so from your home
directory it has nothing to find. The report prints which directory it searched.

Exit status is 0 when nothing failed and 1 when something did. Warnings do not
fail: not having the statusline wrapper is worth knowing and is not a broken
install.

It deliberately does **not** check the Ghostty Automation grant. Asking macOS
for that status can block for over a minute even without prompting, and a
diagnostic that looks like a hang is worse than one that says what it skipped.
Renaming a session from the app asks for the grant when it needs it.

The rest of this page is for what the doctor cannot decide.

---

Organised by what you are seeing, since that is what you know. Each entry says
how to tell which cause you have rather than listing everything that could be
wrong.

If you are reading this through an agent, run `--doctor` first, then read the
section it names. Every fact here is stated so it can be quoted on its own, and
the log at `~/.agent-tracker/logs/agent-tracker.log` is the single place the app
records what it decided and why.

## No sessions appear at all

**First, the answer that is right most of the time: restart the session.** Claude
Code reads its hook configuration when a session starts, so sessions that were
already running when you installed Agent Tracker never report anything. They are
not broken and they will not recover; start a new one, or restart that one.

If a *new* session still does not appear, work down these in order.

**Are the hooks registered?** They live in `~/.claude/settings.json`, or in
`~/.claude/settings.local.json`; either can carry them, so a check that reads
only the first can report a phantom problem. Ask which events are wired rather
than grepping, since `agent-tracker` also appears in the `statusLine` entry and a
raw count answers a different question than it looks like it does:

```sh
python3 -c "
import json, os
hooks = {}
for name in ('settings.json', 'settings.local.json'):
    path = os.path.expanduser('~/.claude/' + name)
    if os.path.exists(path):
        for event, entries in json.load(open(path)).get('hooks', {}).items():
            hooks.setdefault(event, []).extend(entries)
print(sorted(e for e, v in hooks.items()
             if any('agent-tracker' in x.get('command', '')
                    for c in v for x in c.get('hooks', []))))"
```

Or just run `--doctor`, which does exactly this and more.

All seven are expected:

```text
['Notification', 'PreCompact', 'PreToolUse', 'SessionEnd', 'SessionStart', 'Stop', 'UserPromptSubmit']
```

An empty list means the installer did not run or did not finish; run
`./install.sh` again, which is idempotent and backs up your settings first.

**Is the hook writing anything?** Each session gets one JSON file:

```sh
ls -la ~/.agent-tracker/sessions/
```

Empty, with a session running and restarted since install, means the hook is
failing. It is designed never to break your session, which also means it fails
silently, so run it by hand to see what it says:

```sh
echo '{"hook_event_name":"Stop","session_id":"probe"}' \
  | python3 ~/.agent-tracker/bin/agent-tracker-hook.py claude
```

Silence and an exit code of 0 is success. Anything printed is the fault.

**Not** a project-level settings file, despite what you might expect. Hooks from
a project's own `.claude/settings.json` are **merged** with the user-level ones
rather than replacing them, so a repo with its own hooks still reports sessions
normally. Measured rather than assumed: this project defines two of its own hook
events and its sessions are tracked anyway.

The single `statusLine` slot is the opposite, because one command cannot merge
with another; see [usage numbers](#usage-numbers-5h--7d-are-missing) below.

## A session shows no context percentage

Expected, and not a fault, if that session's status line has not rendered yet or
the statusline wrapper is not installed. The context reading is only available in
Claude's statusline payload, so no wrapper means no reading; see
[the statusline wrapper](statusline.md).

The app keeps one careful distinction. A row with **no reading** shows nothing
at all, rather than showing `0%`. "Plenty of room left" and "nothing known" must
not look the same. So a blank means the app has not been told, never that the
window is empty.

Check what it has actually been told:

```sh
python3 -c "import json;d=json.load(open('$HOME/.agent-tracker/claude-statusline.json'));print(d.get('session_id'), d.get('context_window'))"
```

That file holds **one** session's payload, whichever wrote most recently, so
seeing another session's id there is normal. The app accumulates them per
session as they arrive rather than reading it as a snapshot.

## Usage numbers (`5h` / `7d`) are missing

Same root cause, same fix: the numbers exist only in the statusline payload. See
[the statusline wrapper](statusline.md).

Without it, the app learns about a limit only once a request has already been
refused, and most refusals do not say when the window resets.

Four situations produce no usage numbers even *with* the wrapper installed, and
none of them is a bug:

- a project-level `statusLine` shadowing the user-level one
- `claude -p` (print mode)
- background agents and SDK sessions
- an untrusted workspace

A window that has no reading is dropped from the strip rather than shown as zero,
for the same reason as context above.

## Click-to-focus opens the wrong terminal

Almost always because **two sessions are in the same repo**. They share a
directory, so they get the same row title, and terminals report nothing that
tells them apart.

The app does better than a coin flip (rows are spread across the candidate
windows rather than all pointing at the first, and clicking again walks the
rest), but it cannot guarantee each row opens its own window.

**The fix is to give them different names**, which makes the window titles
different, which makes the match exact:

```text
/rename billing spike
```

Run that in the terminal of one of them. Claude owns the rename, so the terminal
tab title follows, and the app matches on exactly that. You can also do it from
the app (right-click → *Rename…*), though see the note in
[rename refuses](#a-rename-is-refused) about which sessions it can reach.

## Click-to-focus does nothing at all

Three different outcomes look like "nothing happened", and they have different
fixes. Tell them apart by what *did* move:

- **Nothing at all, and macOS asks about Accessibility**: the grant is missing.
  See [permissions](permissions.md), and note that a lost grant is fixed by
  **removing and re-adding** the entry, never by toggling it.
- **The terminal comes forward but the wrong window is on top**: the grant is
  fine and the title did not match. That is the ambiguity case above: give the
  session a name.
- **Nothing at all, and no prompt**: no known terminal app is running. The app
  only raises terminals it recognises.

## A rename is refused

Each refusal names its own cause. The three you are most likely to see:

**"Run /rename in that terminal instead."** The app cannot tell which window
belongs to that session. Outside tmux it identifies a window by its title, so the
sessions it cannot reach are exactly the ones sharing a title with a sibling,
which is the case renaming would have fixed. Running `/rename` in the terminal
has no such limitation, because you are already in the right window.

**"That session isn't sitting at a finished turn."** Deliberate and not
negotiable. A rename is typed into a live session and submitted with Return, and
Return pressed at an open permission prompt commits whichever option is focused.
Finish or dismiss what the session is doing, then rename.

**It sits on "Renaming…" for a long time.** Expected on the first rename of a
Ghostty session: macOS's Automation preflight was measured taking over 100
seconds for an app that is running but not yet granted. *Close* cancels. Later
renames are immediate.

Worth knowing: **running sessions inside `tmux` removes the whole class of
window-matching refusals**, because a pane reports its own id and tty, so
nothing is matched by title and no macOS permission is involved.

## The app will not open

On first launch macOS blocks it, and **the dialog's default button deletes the
app**. Click **Done**, never *Move to Trash*, then approve it in System Settings
› Privacy & Security. The README's install section has the full sequence.

This is because the build is not yet notarized, which is blocked on an Apple
Developer Program enrolment rather than on anything technical.

## A session shows as running while Claude sits at the prompt

The row reads *Background: …* or *Background work still running*, but the
terminal shows Claude waiting for you. Claude reports `shell` for as long as a
background shell it started is still running, and the app takes that at its
word: a turn parked on a shell is resumed by the harness when the shell ends.
A shell that never ends, typically a wait loop whose condition can never be
met, keeps the row green indefinitely.

After Settings › Sessions › *Flag a background shell after* (30 minutes by
default) the row turns red for the shell, with how long it has run in place of
the time since the turn ended. The stop control at the end of the row opens a
panel showing the command; *Stop shell* ends it, and Claude wakes with the
output so far. Clicking the row, or visiting its terminal, marks the shell seen
instead and leaves it running. Nothing is stopped without that second click.

If the row never turns red, check that the hook is current (`AgentTracker
--doctor`) and that Claude Code is 2.1.145 or later, which is when `Stop` started
listing background tasks. The state file's `backgroundTasks` field shows what
the hook recorded.

## The doctor reports an unknown registry value

```text
WARN registry format  Claude writes value(s) this build does not know: nameSource "sponsor"
```

Nothing is broken yet. Agent Tracker reads a few fields out of
`~/.claude/sessions/<pid>.json`, a file Claude Code owns and can change without
announcement — the fields are undocumented, so no release note mentions them.
The doctor compares what is actually written there against the values this
build has cases for, and says so when it meets one it has never seen.

The consequence is quiet, which is why the check exists. An unrecognized value
falls to a default: an unknown `nameSource` is treated as a name Claude
invented, so a name **you** chose may stop appearing on its row; an unknown
`status` expresses no opinion, so a session may sit in the wrong group. Both
look like the app forgetting something rather than like an error.

There is nothing to fix locally — the value is Claude's, not yours. Report it
with the version that produced it:

```sh
claude --version
grep -ho '"nameSource":"[^"]*"' ~/.claude/sessions/*.json | sort -u
```

A new value usually means the app needs a case for it in the next release. If
names are already showing wrongly, [renaming a session](#a-rename-is-refused)
still works — the app prefers a name you set in its own UI over anything the
registry says.

The check reads only what the sessions on this machine happen to produce, so
silence is not proof the format is unchanged — only that nothing unfamiliar
turned up.

## Where to look when none of this fits

```sh
tail -f ~/.agent-tracker/logs/agent-tracker.log
```

Settings › Advanced › *Diagnostics* › **Show Log** reveals the same file in
Finder. It is plain text, local only, and capped at 2 MB.

The app writes what it decided and why: every rename attempt, every refusal
with its reason, every permission failure.

State lives in exactly two places, both plain JSON you can read:

| Path | What it holds |
| --- | --- |
| `~/.agent-tracker/sessions/*.json` | one file per session, written by the hook |
| `~/.agent-tracker/claude-statusline.json` | the most recent statusline payload |

Both are overridable with `AGENT_TRACKER_DIR`, which is how the test suite avoids
touching your real data.
