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
  terminal window by title (Claude Code titles windows "✳ &lt;task summary&gt;";
  the summary is read from the session transcript) with the working directory as
  fallback, then raises the window — macOS switches to its Space automatically.

## Getting started

Requirements: macOS 14+, Swift toolchain (Xcode or CLT), Python 3.

```sh
# 1. Onboard — pick your agent CLIs in an interactive checkbox picker,
#    see exactly what will change, confirm. Idempotent, configs backed up.
./install.sh
#    (non-interactive: ./install.sh --agents claude,codex --yes)

# 2. Build and run the menu bar app
swift run AgentTracker

# 3. Start a new agent session — it appears in the menu bar
```

Prefer running the scripts manually? The onboarding just orchestrates them:
`./integrations/install-claude-code.sh` (Claude Code hooks) and
`./integrations/install-codex.sh` (Codex notify handler). To remove everything
again, run `./integrations/uninstall.sh` — it strips only the agent-tracker
entries from your configs (add `--purge` to also delete `~/.agent-tracker`).

On the first click-to-focus, macOS will ask you to grant the app Accessibility
permission (System Settings → Privacy & Security → Accessibility).

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
- **Window matching is best-effort.** Multiple sessions in the same directory
  without distinct window titles may focus the wrong window (the right app and
  Space, though).
- Terminal support is tested with **Ghostty**; iTerm2, Terminal.app, WezTerm and
  kitty are wired up but untested.
- The app runs via `swift run` for now — no .app bundle / login item yet.

## Roadmap

- [ ] Filter dropdown by state when clicking a specific dot
- [ ] macOS notifications on state changes (opt-in, respects Focus)
- [ ] Migrate Codex integration to its native hooks engine (approval-request
      red states)
- [ ] LLM-generated one-line summaries of where each session is at
- [ ] More providers (Kimi, GLM, …) — the state file schema is provider-agnostic
- [ ] Onboarding: install as .app + login item

## License

[MIT](LICENSE)
