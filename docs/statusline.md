# The statusline wrapper

Optional, and the single thing that most changes how much Agent Tracker can tell
you. Installing it is one flag — or the **Claude statusline** picker in the
app's Settings › General, which drives the same installer:

```sh
./install.sh --statusline           # capture; your own statusline keeps rendering
./install.sh --statusline-builtin   # capture AND show Agent Tracker's statusline
# or --no-statusline to decline the question
```

## What it is for

Claude Code hands its status line script the whole session payload on stdin.
That payload is the **only** place Claude offers three things:

| What | Why it matters |
| --- | --- |
| `rate_limits` | how much of the 5-hour and 7-day windows is used, and when each resets, *before* a request is refused |
| `context_window.used_percentage` | the per-row context reading |
| `session_name` | the exact window title, which makes click-to-focus exact rather than approximate |

Without the wrapper the app still works. It learns about a usage limit only once
a request has already been refused, most refusals do not say when the window
resets, rows show no context reading, and window matching falls back to
transcript summaries and path fragments.

## Why it has to occupy a slot

`settings.json` holds exactly one `statusLine` object. There is no array and no
chaining, so capturing the payload means taking that slot.

**The wrapper tees rather than replaces.** It saves the payload where the app can
read it, then becomes whatever status line was configured before, with the same
bytes on stdin. If you had your own status line, you keep seeing it, unchanged.

What it displaced is recorded in `~/.agent-tracker/claude-statusline-wrapped.json`,
deliberately in Agent Tracker's own directory rather than as a private key
inside `~/.claude/settings.json`, because writing your own keys into someone
else's config file is how config files end up unparseable. Uninstalling reads
that file to put your original back.

## Which statusline you see

The capture is the same either way; what renders behind it is a choice, stored
as a `display` key in that same record file:

- **Keep my statusline** (the default, and what plain `--statusline` does): the
  wrapper becomes whatever command it displaced, with the same bytes on stdin.
  An empty slot stays a blank line.
- **Agent Tracker's** (`--statusline-builtin`, or the Settings picker): the
  wrapper becomes the shipped renderer instead, which shows the model, effort,
  context %, the 5h/7d usage windows with their reset times, lines changed this
  session, the git branch with a dirty mark, and the working directory. Your
  previous statusline stays recorded and comes back when you switch away.

Switching between the two installed states edits only the `display` key in
Agent Tracker's own record — `~/.claude/settings.json` is written once at
install and once at restore, never per switch. The app's Settings picker is the
convenient way to flip it; re-running the installer with the other flag does
the same (a plain `--statusline` re-run never silently reverts a builtin
choice).

## Where the payload lands

```text
~/.agent-tracker/claude-statusline.json
```

**One file, holding one session's payload, whichever wrote most recently.** Every
live session rewrites it every few hundred milliseconds. So finding another
session's id in there is normal and not a fault; the app accumulates readings per
session as they arrive rather than reading the file as a snapshot of everything.

Writes are atomic, and the temporary file carries the writing process's pid,
because the writers are concurrent processes sharing one destination; a fixed
`.tmp` name would let two sessions interleave their bytes before either renamed
it.

## If you already have your own status line

You have two options, and the second needs no wrapper at all.

**Let the wrapper run yours behind it.** This is what `--statusline` does, and
what the previous sections describe. Nothing about your status line changes.

**Or dump the payload yourself.** The app also reads
`~/.claude/statusline-last.json`, so if your own script writes its stdin there,
you get exact window titles and per-row context readings with no wrapper
involved. The **usage windows are the exception**: the app reads those only
from the wrapper's own capture, never from a file someone's script happens to
maintain — so the 5h/7d strip stays absent on this route.

## When it produces nothing, and none of it is a bug

- **A project-level `statusLine` shadows the user-level one.** Sessions in that
  project run the project's status line, not the wrapper.
- **`claude -p`** (print mode) renders no status line.
- **Background agents and SDK sessions** likewise.
- **An untrusted workspace** does not run it.

In all four cases the app says it cannot tell rather than claiming you have room
left. A window with no reading is dropped from the usage strip rather than shown
as zero, for the same reason a row with no context reading stays blank: "nothing
known" and "nothing used" must not look the same.

## Removing it

Pick **Off** in Settings › General › Claude statusline, or run
`integrations/install-claude-code.sh --statusline-restore`. Both restore
whatever the wrapper displaced, or remove the `statusLine` entry entirely if
there was nothing there before, and touch nothing else.
`integrations/uninstall.sh` does the same as part of removing everything — see
[uninstall](uninstall.md).

## Design constraints

Worth knowing if you are reading the scripts (the wrapper and the built-in
renderer alike):

- **Python standard library only**, like every integration here.
- **It must never break a session.** Every failure path ends in a silent exit 0,
  including the directory creation. A blank status line is a cosmetic loss; a
  traceback printed onto Claude's status line is not.
- **Git is the renderer's one subprocess**, and the one thing that can stall,
  so every call carries a timeout and any failure just drops the branch
  segment.
