---
name: pr-iterate
description: Address the latest review feedback on the current branch's open PR. Triages each item, implements fixes or replies with reasoning, validates, and commits.
allowed-tools:
  - Agent
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# PR Iterate Skill

You iterate on the open pull request for the current branch. Your job is to fetch the latest review feedback, triage each item, implement the relevant fixes, assess them with the project's CI checks, delegate the commit to the `commit` agent, and explain anything you skipped.

## Step 1 — Verify branch and clean tree (no pushing yet)

```bash
git branch --show-current
git status -s
```

If on `main`, **stop** — tell the user to switch to the feature branch.

If the tree is dirty, **stop** — tell the user:

> You have uncommitted changes. Run `/commit` to land them (or `git stash` to set
> them aside), then rerun `/pr-iterate`. I won't auto-commit them — they may be
> WIP or unrelated to the review feedback.

**Never push mid-iteration** — it triggers the review pipeline pointlessly. You
push exactly **once, and only after every PR comment and title/body edit is in
place** (Step 10), with an explicit refspec
(`git push origin "HEAD:refs/heads/<branch>"`). The automated reviewer snapshots
the PR body + conversation **at push time** and only re-runs on a code push, so
your reply/decline notes and fix summary must already be on the PR before you
push — push first and the reviewer re-runs without them and re-raises issues you
already handled. Bare `git push`, pushes to `main`/`master`, force pushes, and
`gh pr merge` are forbidden — agents push only explicit feature-branch refspecs,
and merging the PR is the human's call.

## Step 2 — Identify the PR

```bash
git branch --show-current
gh pr view --json number,title,url,body
```

If there is no open PR for this branch, **stop** and tell the user to create one first (`/pr-open`).

### Pre-flight: is the base ahead of this branch?

Before iterating, check whether the PR's base has moved:

```bash
TARGET_BASE=$(gh pr view --json baseRefName --jq .baseRefName)
git fetch origin "$TARGET_BASE"
BEHIND=$(git rev-list --count "HEAD..origin/$TARGET_BASE")
```

If `$BEHIND` is non-zero, surface the suggestion and pause:

> `origin/$TARGET_BASE` is ahead by $BEHIND commit(s). Before iterating, consider merging it into this branch so review comments stay anchored and the diff stays clean:
>
> ```bash
> git merge origin/$TARGET_BASE
> ```
>
> Never rebase — rebasing rewrites history and invalidates anchored review comments. Reply `proceed` to iterate anyway, or merge first and rerun `/pr-iterate`.

Do not perform the merge yourself. This is a checkpoint rather than a failure: wait for explicit confirmation to proceed as-is or to merge first, then continue.

## Step 3 — Fetch the latest review feedback

PR feedback lands on **three separate surfaces**. Sweep all three — a query that
checks only one silently drops the rest, which is the usual reason reviewer
feedback gets missed.

```bash
# 1. PR issue comments — where the AUTOMATED reviewer posts. `.github/workflows/pr.yml`
#    runs Codex and UPSERTS its findings into ONE PR issue comment authored by
#    `github-actions[bot]`, marked `<!-- codex-pr-review -->` and ending with the
#    machine-readable trailer `<!-- codex-review: unresolved=N, high=M -->`; it does
#    NOT submit a formal review and leaves NO inline comments, so this is the
#    surface most often missed. The same comment is rewritten in place on every
#    run — always re-read it, never trust a cached copy.
gh pr view --json comments --jq '.comments[] | {author: .author.login, body}'

# 2. Formal reviews — a human "Approve"/"Request changes" with a summary body.
gh pr view --json reviews --jq '.reviews[] | select(.body != "") | {author: .author.login, state, body}'

# 3. Inline review comments — anchored to a file/line. `gh api` expands {owner}/{repo}
#    from repo context but NOT {number}, so resolve the PR number into $PR first.
PR=$(gh pr view --json number --jq .number)
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --jq '.[] | {author: .user.login, path, line, body, created_at}'
```

Parse the PR number, owner, and repo from the output of Step 1.

**Do not conclude "no feedback" prematurely.** The reviewer workflow runs
asynchronously on every push and upserts its comment (and sets the non-blocking
`Codex review` commit status — failure when `unresolved > 0`) only after its
`codex` job finishes; if that check is still queued or running, wait for it
(`gh pr checks <number> --watch`) before trusting an empty sweep.

Collect **all** feedback items across the three surfaces. Deduplicate if the same
point appears in more than one place.

## Step 4 — Triage each feedback item

The reviewer — especially an automated one — is **advisory, not authoritative**. It surfaces nitpicks and edge cases indiscriminately; deciding which to act on is your job. The bar is the PR's stated scope and acceptance criteria, not zero open comments.

For each distinct item, choose one:

1. **Fix** — a genuine bug, security issue, missing edge case, or improvement whose value clearly exceeds its cost. Implement it (Step 5).
2. **Decline** — explain the reasoning in a PR comment (Step 8). Valid grounds: a false positive; already handled elsewhere; a style nit that contradicts project conventions; **correct but low-value** churn (a cosmetic nitpick, or a regression test that does not earn its own iterate→review cycle); **out of scope** for this PR; or infeasible without a larger refactor.
3. **Defer** — a real improvement that belongs in a follow-up issue rather than this PR; note it in a PR comment (Step 8).

When a fix is small and clearly correct, just make it rather than debating. But do not implement a change you consider wrong, pointless, or scope creep merely to clear a comment — a well-reasoned decline is an expected outcome, and "good enough to merge" is a valid verdict once the PR meets its stated scope.

## Step 5 — Implement the relevant fixes

For each item you marked as relevant:

1. Read the affected file(s) in full to understand context.
2. Make the fix using Edit or Write tools.
3. Keep a mental log of what you changed and why.

Group related fixes into a single logical change when possible.

## Step 6 — Assess against CI checks

Run the project's CI pipeline locally:

```bash
make lint    # wraps uvx pre-commit: check-only Swift hooks + auto-fixing file fixers
make test    # swift build + swift test
```

If Package.swift does not exist yet, `make test` is a no-op — note that in the
report rather than treating it as a pass with coverage. There is no non-fixing
lint mode here: `make lint` may auto-fix formatting (markdown/shell/python/
whitespace hooks), and any files it touches simply join the iteration diff that
Step 7 commits. The Swift hooks are check-only — fix their findings with
`make format` or manual edits, never by waiting for lint to rewrite them. If
anything fails and cannot be auto-fixed, stop and fix the issue. Do NOT advance to Step 7 with red checks; you'd just commit broken
code.

## Step 7 — Delegate the commit to the `commit` agent (no push yet)

Invoke the `commit` agent (Agent tool, `subagent_type: commit`) to cluster and
commit the iteration changes. The agent will auto-fix lint issues and refuse to
commit on failure. Don't run `git add`/`git commit` yourself.

Briefly hand it the iteration context so commit messages reflect the review
feedback you addressed (e.g. "iteration changes addressing PR review on
#<pr-number>").

If the commit agent stops because lint fails on something it couldn't auto-fix,
fix it and re-invoke it. Do NOT proceed to Step 8 until the commit exists
locally — posting review comments before the diff is committed leaves the PR
with comments that point at nothing.

**Do not push here.** The commits stay local until Step 10. Comments (Step 8)
and any title/body sync (Step 9) must land on the PR *before* the push, because
the automated reviewer re-reads the conversation at push time.

## Step 8 — Post PR comments (before pushing)

Now that the commit(s) exist locally (not yet pushed), post comments for:

1. **Skipped items** — one comment per declined/deferred item, explaining why:

```bash
gh pr comment {number} --body "$(cat <<'EOF'
**Re: {brief description of feedback item}**

{1–3 sentence explanation of why this was not implemented, with supporting reasoning.}
EOF
)"
```

2. **Summary of implemented fixes** — one comment listing what changed:

```bash
gh pr comment {number} --body "$(cat <<'EOF'
**Iteration fixes:**

- {one-line description of each fix}
EOF
)"
```

Be respectful and specific. Never dismiss feedback without justification.

## Step 9 — Sync the PR title and body with the commit history

PR titles and descriptions in this repo derive from the commit history — there
is no external ticket tracker. An iteration can extend the PR beyond what the
title/body still describe (a review finding that grew into a behavioral change,
or a follow-up surfaced mid-review); keep them in sync after every iteration.

Re-read the full commit range and compare against the current metadata:

```bash
TARGET_BASE=$(gh pr view --json baseRefName --jq .baseRefName)
git log --oneline "origin/$TARGET_BASE"..HEAD
CURRENT_TITLE=$(gh pr view --json title --jq .title)
```

If the title no longer names the dominant change, rewrite it — keep the
Conventional Commits shape (`<type>(<scope>): <short description>`). If the
body's Summary/Changes sections have drifted, update them the same way.

```bash
gh pr edit --title "<type>(<scope>): <short description>"
```

`gh pr edit` is metadata-only — no commit, no push, no CI re-run. Skip this step
entirely when the iteration was pure fix-up and the existing title/body still
describe the PR accurately.

## Step 10 — Push the feature branch once

Everything the reviewer reads — the PR body, the title, and your reply/decline/
fix-summary comments — is now in place. Push the feature branch, explicitly and
exactly once:

```bash
git push origin "HEAD:refs/heads/$(git branch --show-current)"
```

This is the push that re-triggers CI and the automated reviewer; because the
comments and title/body edits already landed, the reviewer sees them and marks
the addressed items resolved instead of re-raising them. Never bare `git push`,
never another branch, never `--force`, never a push targeting `main`/`master`.

## Step 11 — Report back

Return a structured summary to the user:

### Implemented

- List each feedback item you addressed, with a one-line description of the fix.

### Skipped (with comment)

- List each item you skipped and the reason (or "None" if you implemented everything).

### Validation

- Confirm `make lint` and `make test` pass (or note that `make test` was a no-op
  because Package.swift does not exist yet).
- Include the commit hash and PR URL.

## Important rules

- **Push only the current feature branch, explicitly, once** — `git push origin "HEAD:refs/heads/<branch>"` as the **last** step (Step 10), after the fixes are committed *and* every PR comment / title / body edit is in place. The automated reviewer re-reads the conversation at push time, so comment-before-push is mandatory; pushing first makes it re-raise items you already addressed. Never bare `git push`, never a push targeting `main`/`master`, never `gh pr merge` — merging is the human's.
- NEVER commit to `main`. If somehow on that branch, stop immediately.
- NEVER force-push or amend previous commits.
- NEVER skip the Step 6 assessment. All changes must pass `make lint` and `make test` before commit.
- When a fix is small and clearly correct, prefer making it over debating — but a reasoned decline of a wrong, low-value, or out-of-scope item (with the reasoning posted to the PR) is an equally valid outcome. Don't implement churn just to clear a comment.
- Be thorough — read full files, not just the lines mentioned in the review.
