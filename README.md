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
status reason, time in state). Clicking a row jumps straight to that terminal
window — across Spaces — and marks the session as acknowledged.

## How it works

```
Claude Code hooks ──▶                          ┌──▶ menu bar icon (3 dots + counts)
                      ~/.agent-tracker/        │
                      sessions/*.json  ──watch─┼──▶ dropdown session list
                                               │
Codex notify      ──▶                          └──▶ click row → focus terminal window
```

- **No daemon, no polling loops.** Agent CLIs push events through their native
  hook mechanisms; a tiny dependency-free Python script
  (`integrations/agent-tracker-hook.py`) translates each event into a per-session
  JSON state file. The app watches the directory with a dispatch source.
- **Dead sessions are pruned** automatically: each state file records the agent
  CLI's pid, and the app removes files whose process is gone (killed terminal,
  crash) even without a clean `SessionEnd`.
- **Click-to-focus** uses the Accessibility API: it matches the session to a
  terminal window by title (Claude Code titles windows "✳ &lt;task summary&gt;";
  the summary is read from the session transcript) with the working directory as
  fallback, then raises the window — macOS switches to its Space automatically.

## Getting started

Requirements: macOS 14+, Swift toolchain (Xcode or CLT), Python 3.

```sh
# 1. Build and run the menu bar app
swift run AgentTracker

# 2. Install the integrations (both are idempotent and back up your configs)
./integrations/install-claude-code.sh   # registers Claude Code hooks
./integrations/install-codex.sh         # registers Codex notify handler

# 3. Start a new agent session — it appears in the menu bar
```

On the first click-to-focus, macOS will ask you to grant the app Accessibility
permission (System Settings → Privacy & Security → Accessibility).

### State mapping

| Provider | Event | State |
|---|---|---|
| Claude Code | `SessionStart` | idle |
| Claude Code | `UserPromptSubmit`, `PreToolUse`, `PreCompact` | running |
| Claude Code | `Stop` (turn complete), `Notification` (permission/input) | needs you |
| Claude Code | `SessionEnd` | removed |
| Codex | `agent-turn-complete` | needs you |

## Current limitations

- **Codex sessions only surface on turn completion** — Codex's `notify` hook has
  no turn-start event, so Codex sessions don't show a live "running" state yet.
- **Window matching is best-effort.** Multiple sessions in the same directory
  without distinct window titles may focus the wrong window (the right app and
  Space, though).
- Terminal support is tested with **Ghostty**; iTerm2, Terminal.app, WezTerm and
  kitty are wired up but untested.
- The app runs via `swift run` for now — no .app bundle / login item yet.

## Roadmap

- [ ] Filter dropdown by state when clicking a specific dot
- [ ] macOS notifications on state changes (opt-in, respects Focus)
- [ ] Live "running" state for Codex (session file watching)
- [ ] LLM-generated one-line summaries of where each session is at
- [ ] More providers (Kimi, GLM, …) — the state file schema is provider-agnostic
- [ ] Proper .app bundle + launch at login

## License

[MIT](LICENSE)
