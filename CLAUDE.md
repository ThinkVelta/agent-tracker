# Agent Tracker

Keep track of your agent sessions in your MacBook's Menu Bar.

## Project overview

A macOS menu bar app showing the status of running AI agent sessions (active /
idle / waiting for input), with a dropdown session list and notifications.

## Current state

Freshly initialized — no functional code yet. Only repo fundamentals (README,
license, gitignore) exist.

## Planned stack

- Swift + SwiftUI, using `MenuBarExtra` for the menu bar presence
- Native macOS app (no Electron), targeting recent macOS versions

## Conventions

- Keep the app lightweight: it lives in the menu bar, so minimal footprint and
  no unnecessary dependencies.

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
