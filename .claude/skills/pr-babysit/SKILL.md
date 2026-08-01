---
name: pr-babysit
description: Babysit the current branch's open PR until it is merge-ready — watch CI until it turns green (fixing failures), and make sure every piece of review feedback is addressed, either by implementing it or by declining it with a reasoned comment. A watchdog around `/pr-iterate`. Triggers for `/pr-babysit`.
allowed-tools:
  - Agent
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Skill
argument-hint: "[pr-number]"
---

# PR Babysit Skill

You babysit the open pull request for the current branch: keep watching CI and review activity, and do not stop until the PR is **green and fully addressed** — or you are blocked on a decision only the human can make. You are a watchdog wrapped around the existing `/pr-iterate` flow; you never merge.

This repo runs a **single long-lived branch** flow — every PR targets `main` (there is no `dev`). Still resolve the PR's actual base from `baseRefName` rather than assuming `main`.

## Step 0 — Gate: a PR must already exist

```bash
git branch --show-current
# Honor an explicit PR selector (`/pr-babysit 123`, a URL, or a branch); otherwise
# resolve from the current branch. Normalize to the numeric id either way, since
# later steps interpolate `$PR` into a raw REST path (`pulls/$PR/comments`).
PR_INPUT="${ARGUMENTS:-}"
PR=$(gh pr view ${PR_INPUT:+"$PR_INPUT"} --json number --jq .number)
gh pr view "$PR" --json number,url,state,baseRefName
```

- If the current branch is `main`, **stop immediately** — switch to the feature branch first.
- If there is **no open PR** for this branch (and no PR number was passed), **stop** and tell the user: run `/pr-open` first — `/pr-babysit` only watches PRs that already exist.
- If the PR is `MERGED` or `CLOSED`, **stop** and report its state — nothing to babysit.
- Require a clean working tree (`git status -s`). If dirty, stop and tell the user to `/commit` or stash first — babysitting must not entangle unrelated WIP.

`$PR` is now pinned (from the argument or the branch). Record its base branch as `$TARGET_BASE` (from `baseRefName` — normally `main`) and the current time — feedback older than the babysit start that was already addressed in earlier iterations does not count as "new".

## The watch loop

Repeat the following until the exit criteria are met. Each pass:

### 1. Watch CI

```bash
gh pr checks "$PR" --watch
```

`--watch` blocks until all checks finish; if the Bash timeout cuts it off mid-run, just re-invoke it — that is the polling mechanism, not an error. When all checks report, classify:

- **All green** → go to step 2 (review sweep).
- **Only the `Codex review` commit status is red** → that is not a CI failure: the reviewer sets this **non-blocking** status to failure whenever its comment carries `unresolved > 0` findings. It is review feedback wearing a check's clothes — go to step 2 (review sweep), not step 3.
- **Any other red** (including the `PR Reviewer / codex` workflow job itself) → go to step 3 (fix CI).
- **Stuck** (queued/pending with no progress for ~30 minutes) → stop looping and report the stall with the checks table; suggest re-invoking `/pr-babysit` later. Don't spin forever on an idle queue.

### 2. Sweep for unaddressed review feedback

```bash
# The automated reviewer (.github/workflows/pr.yml → Codex) UPSERTS its findings
# into a single PR ISSUE COMMENT by `github-actions[bot]` marked with
# `<!-- codex-pr-review -->` — not a formal review and not inline; the same
# comment is rewritten in place on every run rather than appended. `--json
# comments` is the surface that carries it; the reviews + inline queries cover
# human reviewers.
gh pr view "$PR" --json comments --jq '.comments[] | {author: .author.login, body}'
gh pr view "$PR" --json reviews --jq '.reviews[] | select(.body != "") | {author: .author.login, state, body}'
gh api repos/{owner}/{repo}/pulls/$PR/comments --jq '.[] | {path, line, body, user: .user.login, created_at}'
```

The reviewer comment ends with a machine-readable trailer — parse it instead of
eyeballing the ❌/✅ rows:

```bash
gh pr view "$PR" --json comments \
  --jq '.comments[] | select(.body | contains("<!-- codex-pr-review -->")) | .body' \
  | grep -oE '<!-- codex-review: unresolved=[0-9]+, high=[0-9]+ -->'
```

`unresolved=0` means the reviewer considers everything handled; `unresolved>0`
enumerates open findings in the comment body (and turns the `Codex review`
status red). Because step 1 only advances past `gh pr checks --watch` once the
`PR Reviewer / codex` job is finished, the upserted comment is already current by
the time you sweep — still treat a sweep taken while that job is pending as
inconclusive.

Count as **unaddressed** anything newer than the last handled iteration that is not authored by you/the bot replies you posted. If there is unaddressed feedback → run `/pr-iterate` (it triages each item, implements what is warranted, **declines the rest with a reasoned PR comment** — a justified rejection is as valid an outcome as a fix — validates, commits, and pushes the feature branch once). Its push re-triggers CI, so return to step 1 afterwards.

If the base branch has moved (`git fetch origin && git rev-list --count "HEAD..origin/$TARGET_BASE"` non-zero), surface the merge-not-rebase suggestion exactly as `/pr-iterate` does; merge `origin/$TARGET_BASE` in if the user confirmed that standing preference, then push (explicit refspec) and return to step 1.

The reviewer triggers on `pull_request` types `[opened, synchronize, reopened]` only, so **a comment alone does not re-trigger it**. When a reasoned decline or a reply is the only change and there is nothing left to push, its findings (and the `Codex review` status) stay stale until you re-trigger the run by hand (`gh run list --workflow=pr.yml --branch "$(git branch --show-current)" --limit 1 --json databaseId --jq '.[0].databaseId'`, then `gh run rerun "$RUN"`), and wait for it with `gh pr checks --watch` before re-reading the comment. Skipping this is the single most common way a reviewer status is left stale.

### 3. Fix CI failures

For each failing check:

```bash
gh run view <run-id> --log-failed
```

A red **`PR Reviewer / codex`** job has three distinct causes, and none of them is the reviewer running and finding unresolved issues (that arrives as ❌ rows in its upserted Feedback Summary comment plus a red `Codex review` **status**, and is step 2's business): `OPENAI_API_KEY` missing from the repository secrets, which is a human action to surface and stop on; a transient Codex 401, which the workflow's two-attempt retry usually absorbs; or an **empty review payload**, which the report step fails deliberately via `core.setFailed` instead of logging and passing with no comment and no `Codex review` status, since a silent pass is indistinguishable from a clean review. Re-run the workflow for an empty payload: it points at a transient model or API failure, not at anything wrong with the PR.

Read the actual failure, fix the code, and land it the standard way: delegate the commit to the `commit` agent, then push the feature branch — explicitly, exactly once:

```bash
git push origin "HEAD:refs/heads/$(git branch --show-current)"
```

Never bare `git push`, never another branch, never `--force`, never a push targeting `main` — repo rule: agents push only explicit feature-branch refspecs. The push restarts CI → return to step 1.

If the same check fails twice on the same root cause after a fix attempt, stop and report — don't ping-pong commits against a failure you don't understand.

## Exit criteria

Stop the loop and report **merge-ready** when ALL of:

1. Every CI check is green (the non-blocking `Codex review` status counts too: it must be green, i.e. `unresolved=0`, or every remaining finding must be declined with a reasoned comment).
2. Every review item has been implemented or declined with a reasoned comment — nothing newer than the last iteration is left hanging.
3. The working tree is clean and local equals `origin/<branch>`.

**You never merge.** `gh pr merge` is off-limits and merging is the human's call — "merge-ready" is your terminal state.

## Report back

```text
PR babysit — <merge-ready | blocked | stalled>

  PR:        <url>
  CI:        <n> checks green (<wall-clock watched>)
  Review:    <n> items implemented, <m> declined with comment, <k> pending (should be 0 unless blocked)
  Pushes:    <list of commits pushed during the babysit>
  Your move: review and merge — agents can't `gh pr merge`
```

When blocked, state precisely what decision is needed and the options.

### Change overview (always include)

End the report with a short overview of the most important changes the review +
babysit cycle introduced — what the human about to merge actually needs to know,
not a changelog. Sorted by importance: behavioral and security-relevant fixes
first, then contract or convention changes, then notable doc rewrites. **Omit
the noise** — typo fixes, lint nits, test-only updates, and other quick/minor
improvements don't belong here. One line per change, naming the commit that
introduced it and the review finding (or CI failure) that motivated it.

## Important rules

- **Never `gh pr merge`, never bare `git push`, never force-push, never push to `main`** — repo rules, re-stated here because a long watch loop is exactly where "just this once" creeps in.
- Reviews are advisory, not authoritative — same bar as `/pr-iterate`: don't implement churn just to clear a comment; decline with reasoning instead.
- One concern per pass: don't batch a CI fix and a review iteration into one commit blob; let each loop pass land its own commits.
- Bounded patience beats infinite loops: a stalled queue, a flaky runner, or a repeating failure is a report to the human, not a retry marathon.
