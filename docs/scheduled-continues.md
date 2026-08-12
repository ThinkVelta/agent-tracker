# Scheduled continues

A session that stops on a usage limit can be armed, from the clock on its row,
to resume itself when the window resets. The moment comes from Claude's own
reporting, never from a guess. **Off by default** — it is the
only thing this app does that acts on a session rather than reporting on one, so
it has its own switch in Settings › General.

Two macOS permissions are requested when you arm, and **neither is a hard
requirement** — they buy different things, and a tmux session needs neither:

- **Automation**, to talk to Ghostty. Required to deliver *through Ghostty*, and
  not involved at all for a session running in tmux, which is addressed by pane
  id instead. Also grantable up front from Settings › General › *Permission to
  control Ghostty*, which is the way to get it before you have ever been
  usage-limited.
- **Notifications**, to tell you what happened. Purely announcement: the banner
  is posted after the send, so declining it costs you the banner and nothing
  else. The receipt is still in the panel and the log.

Neither is ever asked for while a schedule is firing. A prompt raised at 04:00
would sit unanswered and block the very delivery it was meant to authorise, so
arming is the only moment either can appear.

**It never wakes your Mac.** A schedule fires if the Mac is awake, or when it next
wakes, and is abandoned after 12 hours — by then the window it was armed for is
long gone and the session has probably been worked in since.

## What it refuses, and why that is most of the feature

Typing into the wrong session is the one thing here that cannot be undone, so
delivery refuses far more often than it fires, and always says why:

- **It can't tell which window is yours.** Ghostty exposes only an id, a title and
  a working directory per surface, and a session cannot report which surface it is
  in. If two windows share a title, both are refused. On one real machine, 2 of 9
  windows were uniquely identifiable. **Running the session inside `tmux` removes
  this problem entirely**: a pane reports its own id and tty, the hook records
  both when the session starts, and nothing is matched by title — so every pane is
  addressable, and no macOS permission is involved.
- **The session isn't at a finished turn.** Return at an open permission prompt
  *approves the focused option*, so anything other than a completed turn is a hard
  refusal, re-checked from disk immediately before writing.
- **Something else is in the foreground.** In `vim`, "Continue" is
  change-to-end-of-line; at a `sudo` prompt it is submitted as a password. The
  agent must own the terminal (`pgid == tpgid`) before a single character is sent.
- **The window or process changed.** The pane recorded when you armed it is
  re-resolved before writing, and any disagreement aborts — a closed window, a
  reused one, a restarted Ghostty (surface ids are only meaningful within one run)
  or a recycled pid all refuse.
- **Only Ghostty and tmux.** Terminal.app is excluded permanently: its entire
  scripting dictionary has one text-injecting command, `do script`, which *runs*
  what you give it.

Every attempt is recorded — sent, refused or failed. The most recent outcome for a
session shows in its scheduling panel (click the clock), and every one is written
to `~/.agent-tracker/logs/agent-tracker.log`. A feature that acts while nobody is
watching owes you a receipt.

**Notifications** are raised when something happened: a send, or a failure that
left a message sitting on a prompt. Refusals stay quiet — they are the normal case
here, not a malfunction, and one alert per refused schedule would be noise. They
are still in the log and the panel.

## Permission modes

Every mode Claude Code is known to run in is allowed, **including
`bypassPermissions`**. Auto-resume adds no capability such a session did not
already have — typing "Continue" yourself has exactly the same effect — so the
only thing that changes is that you are not at the keyboard when it starts. The
arming panel says so plainly for those modes rather than refusing. A mode this
version does not recognise *is* refused, because a mode nobody has seen cannot be
reasoned about.

Claude writes the mode into its transcript, which is read on arming, and also
onto every hook payload, which is the fallback. That redundancy matters more
than it sounds: an absent mode counts as permitted, so a session with no source
at all would slip this gate rather than be stopped by it.

## Where to look when one was refused

The panel behind the clock on the row shows the most recent outcome. Everything
ever attempted is in the log:

```sh
grep -i continue ~/.agent-tracker/logs/agent-tracker.log
```

See also [permissions](permissions.md) for the Automation grant, and
[troubleshooting](troubleshooting.md).
