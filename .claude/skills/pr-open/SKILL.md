---
name: pr-open
description: Create a pull request for the current branch. Analyzes all commits, runs validation, and opens a well-formatted PR on GitHub. Feature branches always target `dev`. Invoke with `/pr-open`.
argument-hint: "[base-branch]"
context: fork
agent: pr-open
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

Delegate to the `pr-open` agent, which enforces the `feature → dev` flow (`main` is what has
been released, and only `/release` moves it), runs validation, and opens a ready-for-review
PR by default via `gh pr create --body-file -`. Use `--draft` only when the user explicitly
asks for a draft PR. See `agents/pr-open.md` for the full ruleset.
