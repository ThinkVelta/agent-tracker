---
name: wt-list
description: List active worktrees with branch, status, sync state, and staleness info. Use this when the user asks what worktrees exist, wants to see what's in flight, check which branches have worktrees, or asks about stale or forgotten parallel work. Also triggers for `/wt-list [--stale]`.
model: haiku
allowed-tools: Bash Read Glob Grep
argument-hint: "[--stale]"
---

# Worktree List

List all active worktrees with rich context: branch, status, sync state, and staleness
detection.

**User input:** $ARGUMENTS

## Step 1 — Gather worktree data

```bash
git worktree list --porcelain
```

Parse the output to extract for each worktree:

- **Path** (`worktree <path>`)
- **HEAD commit** (`HEAD <sha>`)
- **Branch** (`branch refs/heads/<name>`) or `(detached HEAD)`

Identify the main working tree (first entry) and label it as such.

If there are no worktrees beyond the main working tree, report:

> No additional worktrees found. Use `/wt-open` to create one.

Then stop.

## Step 2 — Enrich each worktree

For each worktree, gather the following:

### Clean/dirty status

```bash
git -C "<path>" status --porcelain 2>/dev/null | wc -l | tr -d ' '
```

- `0` → "clean"
- `>0` → report count of modified files

### Ahead/behind remote

```bash
git -C "<path>" rev-list --left-right --count @{upstream}...HEAD 2>/dev/null
```

Output format: `<behind>\t<ahead>`. If no upstream is set, note "no remote".

### Last commit

```bash
git -C "<path>" log -1 --format="%cr|%s" 2>/dev/null
```

This gives relative time and subject (e.g., `2 hours ago|add session store`).

### Staleness check

```bash
git -C "<path>" log -1 --format="%ct" 2>/dev/null
```

Compare the commit timestamp to now. Flag as **stale** if the last commit is **3 or more days
old**.

## Step 3 — Format the output

Present each worktree as a block, for example:

```text
Active worktrees:

  main (main working tree)
    /path/to/repo
    Clean | Last commit: 1h ago "update readme"

  feat/session-notifications
    .claude/worktrees/feat-session-notifications
    Clean | 2 ahead | Last commit: 2h ago "add notification center hook"

  fix/icon-flicker
    .claude/worktrees/fix-icon-flicker
    1 modified file | 0 ahead | Last commit: 20m ago "wip: cache rendered icon"

  chore/upgrade-toolchain
    .claude/worktrees/chore-upgrade-toolchain
    Clean | 1 ahead | Last commit: 3d ago "bump swift-tools-version"
    ⚠ Stale (no commits in 3+ days)
```

If `$ARGUMENTS` contains `--stale`, only show worktrees flagged as stale.

## Step 4 — Recommendations

After the listing, add actionable suggestions for any issues found:

- **Stale worktrees:** "Consider closing stale worktrees with `/wt-close <branch>` to keep your
  workspace tidy."
- **Dirty worktrees:** "Worktree `<branch>` has uncommitted changes. Consider committing them."
- **Behind remote:** "Worktree `<branch>` is behind its remote. Consider pulling."

## Guiding principles

This is a **read-only** command — it reports state but never changes it. The user is asking
"what do I have?" not "fix things for me." If a worktree is in a broken state (missing on disk,
detached HEAD, etc.), report what you can and skip what you can't rather than erroring out.
Suggest `git worktree prune` for missing directories so the user can clean up on their own
terms.
