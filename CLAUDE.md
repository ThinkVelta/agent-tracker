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
  - `StatusIconRenderer.swift` — draws the colored 3-dot menu bar NSImage and
    exposes per-dot hit regions for click→filter mapping
  - `TitleDirectory.swift` — session_id → live window title map, accumulated
    from `~/.claude/statusline-last.json` (exact window matching)
  - `TerminalFocuser.swift` — AX-based window matching + raise
  - `MenuContentView.swift` — dropdown UI
- `integrations/` — hook script + onboarding CLI (Python, stdlib only) +
  idempotent installers + uninstaller

## Commands

- Build: `swift build`
- Test: `./test.sh` — NOT plain `swift test`, which on a CLT-only machine (no
  Xcode.app) builds but silently executes zero tests and exits 0 (see the
  Package.swift header for why)
- Run: `swift run AgentTracker` (menu bar only, no Dock icon)
- Onboard: `./install.sh` (interactive picker; `--agents claude,codex --yes`
  for automation; `integrations/uninstall.sh` reverses it)
- Test hook script manually:
  `AGENT_TRACKER_DIR=/tmp/at-test sh -c 'echo "{\"hook_event_name\":\"Stop\",\"session_id\":\"x\"}" | python3 integrations/agent-tracker-hook.py claude'`
  (`AGENT_TRACKER_DIR` overrides `~/.agent-tracker` for both app and hook;
  `AGENT_TRACKER_CLAUDE_DIR` overrides `~/.claude` for the title directory)

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

## Git workflow

This repo has a single long-lived branch: `main`. Work lands through short-lived feature
branches (`feat/...`, `fix/...`, `chore/...`, `docs/...`) that branch off `main` and PR back
into it.

- Conventional Commits, enforced by the commitizen commit-msg hook
- Push only your own feature branch, always with an explicit refspec
  (`git push -u origin HEAD:refs/heads/<feature-branch>`)
- Open PRs into `main`; a human merges every PR — never `gh pr merge`
- Never `git commit --no-verify` — a PreToolUse hook blocks all of the above mechanically
- PRs receive an automated AI review comment; address its points or reply explaining why not

## Before finishing any task

- `make lint` and `make test` must pass (`make help` lists all targets)
- If `Package.swift` exists, `swift build` must succeed with no new warnings

## Don't be lazy — fix low-risk things directly

When you spot a quick, low-risk improvement while working — a typo, a stale doc, a small bug, a missing guard, dead code your change just orphaned, an obvious cleanup — **just do it**, even when it's unrelated to the current branch, ticket, or PR. Don't downgrade a cheap, safe fix into a "follow-up", a new ticket, or a bullet in a report when doing it then and there costs little.

Still defer — surface it instead of doing it silently — when the change is genuinely risky, large, behaviour-changing, or needs a human decision. **The bar is *risk*, not *relatedness*:** small-and-safe → do it inline and mention it in your summary; risky-or-big → flag it.

## Rules and skills

Always-on, path-scoped conventions live in `.claude/rules/`; repeatable workflows live in
`.claude/skills/` as slash commands (`/commit`, `/pr-open`, `/pr-babysit`, `/pr-iterate`,
`/cleanup`, `/wt-open`, `/wt-close`, `/wt-list`, `/wt-cleanup`, `/wt-help`). See
`.claude/README.md` for how the pieces fit together.
