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
  - `TerminalFocusObserver.swift` — auto-acknowledges sessions whose terminal
    the user visits directly (3s dwell, exact unambiguous matches only)
  - `MenuContentView.swift` — dropdown UI
- `integrations/` — hook script + onboarding CLI (Python, stdlib only) +
  idempotent installers + uninstaller

## Commands

- Build: `swift build`
- Test: `./test.sh` — NOT plain `swift test`, which on a CLT-only machine (no
  Xcode.app) builds but silently executes zero tests and exits 0 (see the
  Package.swift header for why)
- Run: `swift run AgentTracker` (menu bar only, no Dock icon)
- Bundle: `make app` → `dist/AgentTracker.app` (self-validating; ad-hoc signed,
  `CODESIGN_IDENTITY` overrides); `make install` places it in /Applications.
  First-run onboarding shows once (`--onboarding` re-opens it on demand)
- Onboard: `./install.sh` (interactive picker; `--agents claude,codex --yes`
  for automation; `integrations/uninstall.sh` reverses it)
- Docs images: `./scripts/make-docs-images.sh` renders the README's assets from
  synthetic sessions (`scripts/demo-sessions.py`) via the app's own
  `--render-preview`. Never screenshot the real app for docs — that publishes
  whatever you happen to be running. Re-run after any dropdown change and commit
  the result.
- Cut a release: bump `VERSION`, merge to `main`, then `git tag vX.Y.Z && git
  push origin vX.Y.Z`. The tag triggers `.github/workflows/release.yml`, which
  refuses to publish if the tag and `VERSION` disagree or the tagged commit is
  not on `main`. Signing and notarization are driven entirely by repository
  secrets — absent, it ships an ad-hoc signed zip; present, the same workflow
  produces a notarized one with no edits.
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
- **Never paste real private specifics into anything durable** — commit
  messages, PR bodies, code comments, test fixtures. Generic project names are
  fine; strings that *describe business substance* are not (a ticket title
  naming a live payments defect, a task about a named third party, an absolute
  home directory). Paraphrase, or synthesise an equivalent that preserves the
  property being demonstrated — same length, same shape, same edge case — and
  use `/Users/dev/` rather than a real home. This repo is going public, and
  auto-generated release notes and `refs/pull/*` commits are far harder to
  correct afterwards than the working tree.

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
- **Comment before pushing, always**: the Codex reviewer snapshots the PR at the moment new
  commits arrive, so an explanation posted after the push is invisible to the round that push
  triggers. Post the reply comment (fix rationale or reasoned decline) first, then push —
  otherwise every round burns a CI cycle re-litigating what was already answered
- **Write PR bodies and commit messages to a file, then `--body-file` / `-F`**: passing prose
  containing backticks or `$` inline to `gh`/`git` through a shell lets it substitute or execute
  them, silently gutting the text (this has eaten a commit message and a PR body already)

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
