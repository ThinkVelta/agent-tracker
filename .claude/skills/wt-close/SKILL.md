---
name: wt-close
description: Finish work in a worktree — push, remove the worktree, and optionally delete the branch. Use this when the user is done with a worktree, wants to clean up, push and move on, or mentions they no longer need a parallel environment. Also triggers for `/wt-close [branch] [--push] [--force]`.
model: sonnet
allowed-tools: Bash Read Glob Grep
argument-hint: "[branch | path] [--push] [--force]"
---

# Worktree Close

Finish work in a worktree: check for unsaved work, optionally push, remove the worktree, and let
the user decide what happens to the branch.

**User input:** $ARGUMENTS

## Step 1 — Identify the worktree to close

**Priority order:**

1. If `$ARGUMENTS` contains a branch name or worktree path, use that.
2. If the current directory is inside a worktree (not the main working tree), use the current
   worktree.
3. If neither, list worktrees with `git worktree list` and ask the user to pick one.

Parse `git worktree list --porcelain` to find the worktree path and branch. Identify the main
working tree (the first entry) — it cannot be closed.

## Step 2 — Check for uncommitted changes

```bash
git -C "<worktree-path>" status --porcelain
```

**If clean** (empty output): proceed to Step 3.

**If dirty** (uncommitted changes):

Show the user what's pending:

```bash
git -C "<worktree-path>" status --short
```

Then present options:

1. **Commit first** (recommended) — commit in the worktree, then re-run `/wt-close`
2. **Discard changes** — proceed with force removal (requires explicit confirmation)
3. **Abort** — cancel the close operation

If `--force` was in `$ARGUMENTS`, skip this prompt and proceed with force removal.

## Step 3 — Push if requested

If `--push` was in `$ARGUMENTS`, or the user mentioned pushing:

```bash
git -C "<worktree-path>" push -u origin "<branch>"
```

The branch must be named explicitly: agents in this repo only push explicit feature-branch
refspecs — a bare `git push` or anything aimed at `main` is off-limits (and the PreToolUse guard
hook, `.claude/hooks/guard-bash.sh`, blocks it mechanically).

If push fails, report the error and stop. If no `--push` flag, skip this step.

If there are unpushed commits and the user did NOT request `--push`, mention it — but only after
computing the count per Step 4d. Do not state a number you have not computed.

## Step 4 — Verify branch state (do not guess)

Before picking a default in Step 5, you MUST verify the branch's actual state. The branch name
is not evidence. Asserting "PR is open", "PR is merged", or "N unpushed commits" without running
the commands below is a hallucination — do not do it.

Resolve the main repo path (used for all checks below):

```bash
MAIN_REPO=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
```

**4a. Refresh remote tracking refs.** Without this, a remote branch deleted after a merge still
appears to exist locally:

```bash
git -C "$MAIN_REPO" fetch --prune origin
```

**4b. Check PR state via `gh`.** This works even if the remote head branch was deleted
post-merge:

```bash
gh pr list --head "<branch>" --state all --json number,state,mergedAt --limit 1 --jq '.[0]'
```

Interpret the result:

- `state: "MERGED"` → branch landed. Record as **merged**.
- `state: "OPEN"` → PR awaiting review. Record as **open PR**.
- `state: "CLOSED"` and `mergedAt: null` → abandoned. Record as **closed without merge**.
- Empty output → no PR exists for this branch. Fall through to 4c.

**4c. If no PR exists, check merge status against the base branch locally:**

```bash
BASE=$(git -C "$MAIN_REPO" symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's|^origin/||')
BASE="${BASE:-main}"
git -C "$MAIN_REPO" rev-list --count "origin/$BASE..<branch>"
```

- Count `0` → branch fully merged into base. Record as **merged**.
- Count `> 0` → branch has unmerged work. Record as **unmerged**.

**4d. Compute unpushed commits — only if the remote branch still exists:**

```bash
git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/<branch>" && \
  git -C "$MAIN_REPO" rev-list --count "origin/<branch>..<branch>"
```

If `refs/remotes/origin/<branch>` does not exist (typical after merge + auto-delete), do NOT
invent a number — say "remote branch no longer exists" instead.

## Step 5 — Present cleanup options

Ask the user what they'd like to do. Present these choices:

1. **Remove worktree only** — removes the worktree directory but keeps the branch. Good when
   the work might continue later or a PR is still open.
2. **Remove worktree + delete branch** — full cleanup. Good when the branch has been merged or
   is no longer needed. Uses `git branch -d` (safe delete — refuses if unmerged).
3. **Keep everything** — cancel the close. The worktree and the branch remain as-is.

Pick the default from the state recorded in Step 4:

- **merged** → default to option 2
- **open PR** → default to option 1
- **closed without merge** → default to option 1, and mention the PR was closed without merging
- **unmerged** (no PR) → default to option 1

If `--force` was specified, skip the prompt and use option 2. The branch-delete flag still
follows Step 4's recorded state (`-D` for merged, `-d` otherwise) — `--force` only overrides the
prompt and the uncommitted-changes guard, not the branch-safety logic.

## Step 6 — Execute the chosen action

### Option 1: Remove worktree only

```bash
git worktree remove "<worktree-path>"
```

If the worktree is dirty and the user confirmed discard:

```bash
git worktree remove --force "<worktree-path>"
```

### Option 2: Remove worktree + delete branch

**Critical: `cd` into the main repo FIRST, in the same Bash call as the removal.** Claude Code's
Bash tool persists cwd across invocations and resolves it at the start of each call. If the
session is currently inside the worktree, removing it leaves the persistent cwd pointing at a
directory that no longer exists — every subsequent Bash call (a `-D` retry, the Step 7 prune,
anything else) fails immediately with "No such file or directory" before any command runs.
Chaining `worktree remove && branch -d` in one call only protects *that* call; it doesn't fix
the cwd for what comes after. `cd "$MAIN_REPO"` *before* the removal does — the persistent cwd
is updated to the main repo, which still exists after the worktree is gone.

The worktree must also be removed before the branch delete (`git branch -d` refuses to delete a
branch that's checked out in a worktree).

First, resolve the main working tree path:

```bash
MAIN_REPO=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
```

Then pick the delete flag based on Step 4's recorded state:

- **merged** (verified via `gh` or local rev-list) → use `git branch -D`. Squash and rebase
  merges produce different commit SHAs from what `git branch -d` checks against the base branch,
  so `-d` will refuse on a squash-merged branch and orphan it. The PR's MERGED state from GitHub
  is authoritative — the work landed, force-delete is correct.
- **open PR**, **closed without merge**, **unmerged** → use `git branch -d` (safe delete). If it
  refuses, surface the message instead of escalating.

Run everything in a **single Bash call** so `cd` lands before the removal:

```bash
# When Step 4 recorded "merged":
cd "$MAIN_REPO" && git worktree remove "<worktree-path>" && git branch -D "<branch>"

# Otherwise:
cd "$MAIN_REPO" && git worktree remove "<worktree-path>" && git branch -d "<branch>"
```

If `git branch -d` fails (branch not fully merged and Step 4 didn't record "merged"), tell the
user:

> Branch '<branch>' has unmerged commits. Keeping the branch. To force-delete:
> `git branch -D <branch>`

The worktree is already gone at that point, and the cwd is safely in the main repo, so this is a
recoverable end state — not a failure that needs retrying.

### Option 3: Keep everything

Do nothing. Confirm to the user that the worktree is still active.

## Step 7 — Prune and confirm

```bash
git -C "$MAIN_REPO" worktree prune
```

(Step 6 already moved cwd to `$MAIN_REPO`, so a bare `git worktree prune` would also work — `-C`
makes it explicit and survives any future cwd drift.)

Print a summary:

```text
Worktree closed.

  Path:    <worktree-path> (removed)
  Branch:  <branch> (deleted | kept | pushed)
```

## Guiding principles

**The main working tree is not a worktree.** It's the user's primary repo checkout — removing it
would be catastrophic. If someone accidentally targets it, explain the difference.

**Uncommitted work is sacred.** Silently discarding changes is one of the worst things a tool
can do. The user should always see what's at risk and explicitly choose to discard. The
`--force` flag exists for when they've already made that choice.

**Default to `git branch -d` (safe delete) — but `-D` is correct when the PR is verified
merged.** `-d` checks whether the branch's commits are reachable from the base branch, which
fails for squash and rebase merges even though the work has landed. So when Step 4 recorded
**merged** (via `gh` MERGED state or local rev-list count of 0), use `-D` — the merge signal is
authoritative. For every other state, stick with `-d` and surface the refusal to the user
instead of overriding it.

**Use `git worktree remove`, not `rm -rf`.** Git tracks worktree metadata internally; removing
the directory without telling git leaves stale references that cause confusing errors later. If
anything goes wrong, `git worktree prune` cleans up the metadata.
