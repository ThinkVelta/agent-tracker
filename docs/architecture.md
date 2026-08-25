# How it works

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/architecture-dark.png">
  <img alt="Claude Code writes state files; Agent Tracker watches them; you get a menu bar icon, a session list and click-to-focus" src="../assets/architecture-light.png" width="700">
</picture>
</div>

## No daemon

Claude Code pushes events through its native hook mechanism. A dependency-free
Python script (`integrations/agent-tracker-hook.py`, installed to
`~/.agent-tracker/bin/`) translates each event into a per-session JSON state
file, and the app watches those directories with a `DispatchSource` file-system
object source, one per watched directory, firing on write.

One light timer backs that up, a re-read every second by default, paced by
Settings › Sessions › *Background check every*, which prunes dead sessions and
refreshes relative timestamps. It is a backstop rather than the mechanism: the
watcher is what makes the app feel immediate, and the timer catches what a file
event cannot say, a process that died without writing anything.

Seven events are registered: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PreCompact`, `Stop`, `Notification`, `SessionEnd`.

**Dead sessions are pruned automatically.** Each state file records the CLI's
pid, and the app removes files whose process is gone, a killed terminal or a
crash, where no clean `SessionEnd` ever arrives.

## The two things on disk

| Path | Written by | Holds |
| --- | --- | --- |
| `~/.agent-tracker/sessions/*.json` | the hook | one file per session |
| `~/.agent-tracker/claude-statusline.json` | the statusline wrapper | the most recent payload, whichever session wrote last |

Both are plain JSON and readable. `AGENT_TRACKER_DIR` overrides the base
directory for the app and the hook alike, which is how the test suite avoids
touching real data.

**A run one session's tool started is not a session of its own.** A `claude -p`
launched by a script from a session's Bash tool has its own session id and fires
the same hooks, so it gets a state file too. The hook records the enclosing
`claude` process as `spawnedByPid`, and the app leaves such a row out of the
list and the counts while that process lives: its work is the parent row's, and
it has no terminal to jump to. The file stays, so nothing is lost if the link
is wrong.

The statusline file being **last-writer-wins across sessions** is a property the
app is built around rather than a limitation it works around: readings are
accumulated per session id as they arrive, and the file is never treated as a
snapshot of every session.

## Click-to-focus

Matches the session to a terminal window, then raises it through the
Accessibility API; macOS switches Spaces on its own.

The exact window title is learned live from Claude's statusline payload, which
carries `session_id` and `session_name` together. The terminal titles the window
with that name behind a status glyph, which the matcher strips before comparing.

Claude hands that payload to a status line script and nowhere else, so the app
reads it from either of two files:

- `~/.claude/statusline-last.json`, if your own script dumps its stdin there
- the copy the [statusline wrapper](statusline.md) saves

With neither, transcript task summaries (`✳ <task summary>`) and
working-directory fragments remain as fallbacks.

**This is also why renaming fixes ambiguity.** The session's name is what the
matcher compares first (read from Claude's session registry, with the statusline
payload as fallback), and `/rename` sets it, so naming two sessions in one repo
differently makes both addressable, with no configuration.

## Deriving "needs you" is not just reading `Stop`

**A finished turn is not always finished work.** Claude's `Stop` fires when the
assistant's turn ends, which is not the same thing: a turn that backgrounded a
shell resumes when that shell finishes, and one that handed off to subagents or
teammates is not over either.

Claude publishes its own status for each of those (`shell` for background work,
`busy` for delegated work), so a red row is re-derived as running until the
session genuinely settles. It goes red once, at the end, rather than blinking on
every hand-off.

**A background shell that never finishes is "needs you" after all.** A shell
that stays `shell` for hours is usually a polling loop whose exit condition can
never come true; from outside, the one thing that distinguishes it from a long
build is that the harness never wakes the session. The `Stop` payload lists the
shells still running (Claude Code 2.1.145 and later), the hook records each one
with the moment it was first seen, and once the oldest has outlived Settings ›
Sessions › *Flag a background shell after* (30 minutes by default) the row stops
being re-derived and goes red for the shell instead, showing what it was started
for and how long it has run. Its trailing control opens a panel that can end
the shell, which is what actually resolves the situation: Claude sees the task
exit and is woken with whatever it printed. Marking the row seen instead
remembers that shell, so a dev server that legitimately runs all day is flagged
once and not on every turn.

**A dialog is "needs you" whatever the hooks said.** A session showing a
permission prompt, sandbox request or elicitation publishes `waiting`, and the row
turns red quoting what Claude is blocked on. Acknowledged rows are left alone, so
clearing a row by hand always sticks.

**An idle prompt is not a permission prompt.** Claude's `Notification` hook fires
for both, and only its `notification_type` tells them apart. The hook records it,
and a red that came from `idle_prompt` (the turn has sat still for a while) is
re-derived like a `Stop` red: running for as long as Claude reports `shell` or
`busy`. A permission prompt is never re-derived, and a notification whose type
the hook did not record is treated as one.

## Writing into a terminal

Two features write rather than read: scheduled continues and renaming from the
app. Both go through the same channel and the same proof-then-write ordering, and
both refuse rather than guess.

Two channels exist, and the tmux one is checked first:

- **tmux**: the pane reports its own id and tty, recorded by the hook at session
  start. Nothing is matched by title, and no macOS permission is involved.
- **Ghostty**: surfaces are matched by title, which needs the Automation grant
  and can be ambiguous.

tmux is tried first rather than as a fallback, specifically so a session that
needs no Automation grant is never asked for one.

The refusals, and why they are most of the feature, are in
[scheduled continues](scheduled-continues.md).

## Where the code lives

| Path | Concern |
| --- | --- |
| `Sources/AgentTracker/SessionStore.swift` | loads and watches state files, prunes dead pids |
| `Sources/AgentTracker/StatuslineDirectory.swift` | accumulates per-session statusline facts |
| `Sources/AgentTracker/ClaudeSessionRegistry.swift` | reads Claude's own `~/.claude/sessions/<pid>.json` |
| `Sources/AgentTracker/TerminalFocuser.swift` | Accessibility window matching and raising |
| `Sources/AgentTracker/TmuxScripting.swift` | the tmux channel |
| `Sources/AgentTracker/SessionTarget.swift` | resolves where a session's terminal is |
| `Sources/AgentTracker/StatusIconRenderer.swift` | draws the menu bar icon and its click regions |
| `integrations/` | hook, statusline wrapper, installers, onboarding |

`CLAUDE.md` covers the conventions for working *on* the code, which is a
different question from how it runs.
