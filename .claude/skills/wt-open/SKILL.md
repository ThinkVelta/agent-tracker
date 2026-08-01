---
name: wt-open
description: Create or reopen a git worktree for parallel development. Use this whenever the user wants to work on something in parallel, start a new task without disrupting their current branch, spin up an isolated environment for an agent, or mentions worktrees, parallel branches, or "work on X separately". Also triggers for `/wt-open [branch | task description]`.
model: sonnet
allowed-tools: Bash Read Glob Grep
argument-hint: "[branch | task description] [--base <branch>] [--no-build]"
---

# Worktree Open

Create or reopen a git worktree for parallel development, then guide the user to launch a
Claude Code session in it.

**User input:** $ARGUMENTS

## Step 1 — Parse the user's intent

Determine what the user wants from `$ARGUMENTS`:

| Input pattern                                                                                                           | Action                                 |
| ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Empty (no arguments)                                                                                                    | Ask the user what they want to work on |
| Looks like a branch name (contains `/`, or starts with `feat/`, `fix/`, `chore/`, `refactor/`, `docs/`, `ci/`, `test/`) | Use as the branch name directly        |
| Natural language (a task description like "add session notifications")                                                  | Derive a branch name (see below)       |

### Deriving a branch name from a task description

Generate a branch name following this convention:

- Pattern: `<type>/<1-4-word-slug>`
- Type: `feat`, `fix`, `refactor`, `chore`, `docs`, `ci`, `test` — infer from the description
- Slug: lowercase, hyphen-separated, max 4 words, no special characters
- Examples: `feat/session-notifications`, `fix/icon-flicker`, `chore/upgrade-toolchain`

Do not ask the user to confirm the branch name, just use it and proceed immediately.

Validate whatever branch name you end up with:

```bash
git check-ref-format --branch "<branch-name>"
```

If it fails, fix the name (or ask) before creating anything.

## Step 2 — Determine base branch

If the user specified `--base <branch>` in their arguments, use that.

Otherwise, default to `main` — this repo has a single long-lived branch. If the current branch
looks like a feature branch and the user is creating a sub-feature, confirm whether they want to
branch from `main` or from the current branch instead. Use multiple-choice for easy user
selection.

## Step 3 — Check if this worktree already exists

Run:

```bash
git worktree list --porcelain
```

Derive the expected worktree directory. Slashes are flattened to hyphens so the branch name
maps to a single directory level (e.g. `feat/auth` → `.claude/worktrees/feat-auth`):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_DIR="${REPO_ROOT}/.claude/worktrees/$(printf '%s' "<branch-name>" | tr '/' '-')"
```

**If the worktree directory exists and is valid** (has a `.git` file):

- This is a **reopen**. Nothing to create — skip to Step 5 and report `Status: reopened`.

**If the branch exists but has no worktree**:

- Create a worktree for the existing branch (Step 4, existing-branch form).

**If neither exists**:

- Create both the branch and worktree (Step 4, new-branch form).

## Step 4 — Create the worktree

**New branch.** Fetch the base first and branch off `origin/<base>` (with `--no-track`) rather
than the local ref, so a stale local `main` never produces a worktree that's already behind:

```bash
git fetch origin "<base-branch>" && \
  git worktree add --no-track -b "<branch-name>" "$WORKTREE_DIR" "origin/<base-branch>"
```

If the repo has no `origin` remote (or the fetch fails because the base only exists locally),
fall back to branching off the local ref:

```bash
git worktree add -b "<branch-name>" "$WORKTREE_DIR" "<base-branch>"
```

**Existing branch:**

```bash
git worktree add "$WORKTREE_DIR" "<branch-name>"
```

Git only allows a branch to be checked out in one worktree at a time, so `git worktree add`
refuses if the branch is already in use elsewhere. If that happens, surface the error clearly so
the user knows which worktree has it.

## Step 5 — Warm the build (optional)

Unless `--no-build` was in `$ARGUMENTS`, run an initial build inside the worktree. SwiftPM keeps
its `.build/` directory per checkout, so a fresh worktree starts cold — warming it here means
the first agent session doesn't pay the full compile cost:

```bash
(cd "$WORKTREE_DIR" && swift build)
```

A build failure here is **non-fatal**: report it (the branch may simply not compile yet), but
the worktree is still ready to use.

## Step 6 — Print result and next steps

Print **exactly** this format — same fields, same order, same indentation, every time:

```text
Worktree ready!

  Branch:  <branch-name>
  Path:    <worktree-path>
  Status:  new | reopened

  To start working:
  cd <worktree-path>
  claude   # launch Claude Code in this worktree
  code .   # or open in VSCode
```

## Design principles

This skill is **deterministic** — the same branch name always produces the same worktree path,
so the user can bookmark paths and expect consistency. It's also **idempotent** — running it
twice with the same branch reopens rather than duplicates, which means the user never has to
worry about accidentally creating a mess.

If a step fails partway through, just report what happened. Don't try to auto-clean — partial
state is easier for the user to inspect and fix (via `/wt-close`) than state that was silently
deleted.
