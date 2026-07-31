# Agent Tracker

Keep track of your agent sessions in your MacBook's Menu Bar.

## Project overview

A macOS menu bar app showing the status of AI agent CLI sessions (Claude Code,
Codex) as three dots with counts — red = needs you, green = running, grey =
idle — with a dropdown session list and click-to-focus that jumps to the
session's terminal window across Spaces.

## Architecture

Event-driven, no daemon: agent CLIs push lifecycle events via their native hook
mechanisms (Claude Code `hooks`, Codex `notify`) into
`integrations/agent-tracker-hook.py`, which writes one JSON state file per
session to `~/.agent-tracker/sessions/`. The SwiftUI app watches that directory
and renders state. Codex is additionally tracked live in-app by scanning its
rollout files. See README for the full picture.

- `Sources/AgentTracker/` — SwiftUI app (SPM executable, no Xcode project)
  - `SessionStore.swift` — loads/watches state files, prunes dead pids
  - `CodexSessionScanner.swift` — watches `~/.codex/sessions` rollouts
    read-only (`task_started`/`task_complete`/`turn_aborted` events);
    lsof-based liveness; subagent threads excluded
  - `StatusIconRenderer.swift` — draws the colored 3-dot menu bar NSImage
  - `TerminalFocuser.swift` — AX-based window matching + raise
  - `MenuContentView.swift` — dropdown UI
- `integrations/` — hook script + onboarding CLI (Python, stdlib only) +
  idempotent installers + uninstaller

## Commands

- Build: `swift build`
- Test: `swift test`
- Run: `swift run AgentTracker` (menu bar only, no Dock icon)
- Onboard: `./install.sh` (interactive picker; `--agents claude,codex --yes`
  for automation; `integrations/uninstall.sh` reverses it)
- Test hook script manually:
  `AGENT_TRACKER_DIR=/tmp/at-test sh -c 'echo "{\"hook_event_name\":\"Stop\",\"session_id\":\"x\"}" | python3 integrations/agent-tracker-hook.py claude'`
  (`AGENT_TRACKER_DIR` overrides `~/.agent-tracker` for both app and hook)

## Conventions

- Keep the app lightweight: it lives in the menu bar — minimal footprint, no
  third-party dependencies (Swift stdlib/Apple frameworks; Python stdlib only).
- The hook script must never block or break an agent session: always exit 0,
  print nothing on success.
- State file schema is provider-agnostic (`schema` field is versioned); new
  providers should reuse it rather than invent their own.
- Installers must be idempotent and back up user configs before editing.
- Onboarding (`integrations/onboard.py`) must stay stdlib-only and degrade
  gracefully without a TTY (flag-driven fallback, no hangs, no tracebacks).
