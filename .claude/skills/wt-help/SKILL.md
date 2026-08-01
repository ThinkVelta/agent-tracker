---
name: wt-help
description: Answer common questions about working with worktrees — VSCode integration, gitignore, build artifacts, workflow tips. Use this when the user asks how worktrees work, why something looks different in their editor, how to see diffs, or has any question about the worktree setup. Also triggers for `/wt-help [topic]`.
model: haiku
allowed-tools: Bash Read Glob Grep
argument-hint: "[question]"
---

# Worktree Help

`$ARGUMENTS` is the user's question. If empty, print the **Overview** section below verbatim.
Otherwise, answer their question using the **FAQ** section as your primary reference, falling
back to your knowledge of git worktrees and this repo's setup.

Keep answers concise and practical. When relevant, include `code .claude/worktrees/<branch-dir>`
— it's the single most useful tip for new users.

---

## Overview (print when `$ARGUMENTS` is empty)

The `/wt-*` skills are a thin wrapper around git worktrees that let you run multiple branches of
this repo in parallel, each in its own isolated directory.

**Why it exists.** Switching branches mid-task is disruptive: you stash, rebuild, lose state.
Worktrees give each branch its own directory and its own SwiftPM build cache — so you (or a
parallel Claude agent) can spin up a separate task without touching what you're already working
on. The skills automate the lifecycle bookkeeping.

### Links

- Git worktrees docs: https://git-scm.com/docs/git-worktree

**Available `/wt-*` skills**

| Command                                              | Purpose                                                     |
| ---------------------------------------------------- | ----------------------------------------------------------- |
| `/wt-open [branch or description] [--base <branch>]` | Create or reopen a worktree (build warm-up included)        |
| `/wt-list [--stale]`                                 | List active worktrees with branch, sync state, staleness    |
| `/wt-close [branch] [--push] [--force]`              | Push, remove the worktree, optionally delete the branch     |
| `/wt-cleanup [--dry-run]`                            | Batch cleanup of stale worktrees and orphaned branches      |
| `/wt-help [question]`                                | This help — ask any worktree question in natural language   |

Ask `/wt-help <your question>` for anything specific (VSCode setup, build artifacts, etc.).

---

## FAQ

**Q: How do I see a worktree in VSCode?**
Open it as its own window: `code .claude/worktrees/<branch-dir>`. The main repo's Source Control
panel won't show worktree changes — that's by design (worktrees are gitignored). Alternative:
File → Add Folder to Workspace for a multi-root setup.

**Q: Why is `.claude/worktrees/` in `.gitignore`?**
Required. Worktrees are git's own checkout mechanism, not nested repos. Without the gitignore
entry, git would try to track the worktree's files as content of the parent repo.
`git worktree list` is how git tracks them.

**Q: What's the typical workflow?**
`/wt-open <task>` → `code .claude/worktrees/<branch-dir>` → work & commit → `/wt-close --push`.
Use `/wt-list` to see everything in flight.

**Q: Can I run multiple worktrees at once?**
Yes — that's the whole point. Each has its own checkout and build directory. Run `/wt-list` to
see them all. A common pattern: one worktree for your main task, others for parallel Claude
agents working on smaller things.

**Q: Do worktrees share build artifacts?**
No. SwiftPM's `.build/` directory is per checkout, so each worktree compiles independently —
that's why `/wt-open` warms the build with `swift build` after creating one. `swift build`,
`swift test`, and `swift run AgentTracker` all work normally inside a worktree.

**Q: What if I forget about a worktree?**
`/wt-list --stale` shows worktrees with no recent activity. `/wt-cleanup` batch-removes stale
ones (use `--dry-run` first to preview).

**Q: Is the main repo affected when I work in a worktree?**
No. The main repo's working directory and branch are untouched. Only the shared `.git` directory
is updated when you commit (which is the same as any branch switch).

**Q: How do I delete a branch and its worktree completely?**
`/wt-close <branch> --force` removes the worktree and deletes the local branch. Add `--push`
first if you want to push before tearing down.
