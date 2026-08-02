# Agent Tracker

Keep track of your agent sessions in your MacBook's Menu Bar.

## What is this?

Agent Tracker is a lightweight macOS menu bar app that gives you an at-a-glance
view of your running AI agent sessions (Claude Code, Codex, …) — so you always
know what's running, what's waiting on you, and what's done, without cycling
through terminal windows and desktops.

The menu bar shows three dots with counts:

- 🔴 **Needs you** — a session finished its turn or is waiting for permission/input
- 🟢 **Running** — the agent is actively working
- ⚪ **Idle** — session open, nothing pending

Clicking the icon opens a dropdown listing every session (project, provider,
status reason, time in state) — and clicking a specific dot opens it
pre-filtered to that state (click the same dot again to close; the in-dropdown
chips drive the same filter). Clicking a row jumps straight to that terminal
window — across Spaces — and marks the session as acknowledged when the
raised window is identifiably that session's (a strictly better title match
than every sibling). Visiting a session's terminal yourself works too: once
its window has been focused for a few seconds, the session is
auto-acknowledged (exact, unambiguous title matches only — ties never guess).

## How it works

```text
Claude Code hooks ──▶                            ┌──▶ menu bar icon (3 dots + counts)
                       ~/.agent-tracker/         │
Codex notify      ──▶  sessions/*.json  ──watch──┼──▶ dropdown session list
                                                 │
~/.codex/sessions ──▶  read-only rollout watch ──┴──▶ click row → focus terminal window
```

- **No daemon; event-driven at the core.** Agent CLIs push events through their
  native hook mechanisms; a tiny dependency-free Python script
  (`integrations/agent-tracker-hook.py`) translates each event into a per-session
  JSON state file. The app watches directories with dispatch sources/FSEvents —
  the only periodic work is a lightweight 30-second `lsof` liveness check for
  Codex processes.
- **Codex is tracked live without any config change**: the app also watches
  Codex's own rollout files in `~/.codex/sessions` (read-only) for
  `task_started`/`task_complete`/`turn_aborted` events, so Codex sessions show
  running/needs-you/idle states in real time. The `notify` hook is just an
  extra push signal on top. Codex multi-agent fan-out is collapsed into its
  root session: subagent threads get their own rollouts and even fire `notify`
  per subagent turn, and the app identifies and absorbs them (one session, one
  row) instead of showing a phantom "needs you" per finished subagent.
- **Dead sessions are pruned** automatically: each state file records the agent
  CLI's pid, and the app removes files whose process is gone (killed terminal,
  crash) even without a clean `SessionEnd`. Codex sessions are pruned via an
  `lsof`-based liveness check when their `codex` process exits.
- **Click-to-focus** uses the Accessibility API: it matches the session to a
  terminal window by title, then raises the window — macOS switches to its
  Space automatically. For Claude Code the exact window title is learned live
  from `~/.claude/statusline-last.json`: it carries `session_id` +
  `session_name`, and the terminal titles the window with that name behind a
  status glyph, which the matcher strips before comparing. The file is not
  produced by default — it appears when your Claude Code statusline script
  dumps its stdin payload there (e.g. a `tee ~/.claude/statusline-last.json`
  at the top of `statusline.sh`). Transcript task summaries
  ("✳ &lt;task summary&gt;") and working-directory fragments remain as
  fallbacks when it is absent.

## Install

Requirements: macOS 14+.

Download the latest `AgentTracker-x.y.z.zip` from
[Releases](https://github.com/ThinkVelta/agent-tracker/releases/latest), unzip
it, and drag **AgentTracker.app** to `/Applications`. Launch it — the first-run
window walks you through granting Accessibility, connecting your agent CLIs, and
starting at login.

If macOS refuses to open it on first launch, **right-click the app and choose
Open**, then confirm — only the first launch needs it. Each release's notes say
whether that step applies, because they are written from how that build was
actually signed.

Settings › About checks for newer releases; there is no auto-updater and nothing
phones home on its own.

## Build from source

Requirements: the above, plus a Swift toolchain (Xcode or CLT) and Python 3.

```sh
# Build AgentTracker.app and install it into /Applications
make install

open /Applications/AgentTracker.app
```

The app is assembled straight from the SwiftPM build (`make app` if you only
want `dist/AgentTracker.app`), ad-hoc signed by default — set
`CODESIGN_IDENTITY` to a Developer ID for a distributable build. Installing as
a bundle is what makes the Accessibility grant stick to the app (running via
`swift run` attributes it to your terminal) and enables start-at-login.

For development, `swift run AgentTracker` still works exactly as before.

### Cutting a release

Bump `VERSION`, merge to `main`, then tag it:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The tag triggers `.github/workflows/release.yml`, which refuses to publish if
the tag and `VERSION` disagree. Signing and notarization are driven entirely by
repository secrets — absent, the workflow ships an ad-hoc signed zip; present,
the same workflow produces a notarized one with no edits.

Prefer the command line for the agent hookup? `./install.sh` is the same
onboarding as a checkbox picker (non-interactive:
`./install.sh --agents claude,codex --yes`), orchestrating
`./integrations/install-claude-code.sh` and `./integrations/install-codex.sh`.
Everything is idempotent and configs are backed up before editing. To remove it
all again — hooks, the installed app, its preferences — run
`./integrations/uninstall.sh` (add `--purge` to also delete
`~/.agent-tracker`).

### State mapping

| Provider | Event | State |
|---|---|---|
| Claude Code | `SessionStart` | idle |
| Claude Code | `UserPromptSubmit`, `PreToolUse`, `PreCompact` | running |
| Claude Code | `Stop` (turn complete), `Notification` (permission/input) | needs you |
| Claude Code | `SessionEnd` | removed |
| Codex | `task_started` (rollout) | running |
| Codex | `task_complete` (rollout), `agent-turn-complete` (notify) | needs you |
| Codex | `turn_aborted` (rollout, you interrupted) | needs you |

Codex sessions are auto-pruned within ~30 seconds of their `codex` process
exiting (`lsof`-based liveness check on the rollout file).

## Current limitations

- **Codex approval prompts don't surface as red yet** — rollouts don't record
  them; planned via Codex's new native hooks engine.
- **Window matching is exact only when a title source exists.** Claude Code
  sessions get exact titles when a statusline script dumps its payload to
  `~/.claude/statusline-last.json`; without it, matching falls back to
  transcript summaries and path fragments.
- **Sessions sharing one directory cannot be told apart.** Several Codex
  sessions in one repo all title their window with the bare project name, and
  all report the same working directory, so nothing distinguishes them. Their
  rows are spread over the candidate windows rather than all pointing at the
  first one, and repeated clicks walk the rest, so a second row usually opens a
  second terminal — but nothing here identifies *which* window is whose, and two
  rows can still land together when fewer windows are visible than there are
  sessions. Neither Ghostty nor Codex exposes a per-window identity that would
  settle it; `WindowIdentity` documents what was measured.
- Terminal support is tested with **Ghostty**; iTerm2, Terminal.app, WezTerm and
  kitty are wired up but untested.
- The default `make app` build is ad-hoc signed: Accessibility sticks to that
  exact binary, so rebuilding and reinstalling **invalidates the old grant** —
  and toggling the stale entry in System Settings does nothing. Remove
  AgentTracker from the Accessibility list with **−** and re-add it (or
  `tccutil reset Accessibility com.thinkvelta.agent-tracker`). To make grants
  survive rebuilds, create a signing identity once (Keychain Access →
  Certificate Assistant → Create a Certificate… → "AgentTracker Local", type
  *Code Signing*) and build with
  `CODESIGN_IDENTITY="AgentTracker Local" make install`.

## Roadmap

- [ ] macOS notifications on state changes (opt-in, respects Focus)
- [ ] Migrate Codex integration to its native hooks engine (approval-request
      red states)
- [ ] More providers (Kimi, GLM, …) — the state file schema is provider-agnostic
- [x] Onboarding: install as .app + login item

## License

[MIT](LICENSE)
