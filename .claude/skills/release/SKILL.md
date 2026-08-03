---
name: release
description: Cut a release. Derives the version bump from the commits since the last tag, lands the VERSION bump as a PR, then tags the merge commit once a human has merged it, and verifies what actually shipped. Use this when the user wants to publish a version, cut a release, or ship what is on main. Triggers for `/release`, `/release patch|minor|major`, `/release 0.3.0`, `/release --dry-run`.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
argument-hint: "[patch | minor | major | X.Y.Z] [--dry-run]"
---

# Release

You cut a release of this repo. A release is a **pushed tag**: nothing else triggers
`.github/workflows/release.yml`, and no merge to `main` publishes anything on its own.

Releasing takes two invocations, because the `VERSION` bump has to land through a PR that a
human merges. Do not try to collapse them. Work out which half you are in from the repo's
state (Step 0) rather than from memory, so an interrupted release resumes correctly.

The reason this is a skill and not CI: **choosing the bump is a judgement call**, and a
published release cannot be taken back. You read what changed and propose a version; the human
approves it.

**User input:** $ARGUMENTS

## Step 0 — Work out which half you are in

```bash
git fetch --tags origin main
DECLARED=$(git show origin/main:VERSION | tr -d '[:space:]')   # source of truth
LATEST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
git ls-remote --tags origin "refs/tags/v$DECLARED"             # empty means unreleased
gh release view "v$DECLARED" --json tagName --jq .tagName 2>/dev/null || echo "not published"
```

- **`v$DECLARED` already exists** (tag or release): the version on `main` is spent, so this is
  **Phase A**, prepare the bump. Continue at Step 1.
- **`v$DECLARED` does not exist**: a bump has already landed on `main`, so this is **Phase B**,
  tag it. Skip to Step 5, releasing `$DECLARED`.

If Phase B and you did not prepare that bump yourself, say so and show the human the diff of
`VERSION` and who landed it before going further. A stray bump in an unrelated PR is the one
way to reach Phase B by accident.

## Step 1 — Refuse to start from an unclear place

All of these, before touching anything:

```bash
git branch --show-current      # must be main
git status --porcelain         # must be empty
git rev-list --count origin/main..HEAD   # must be 0 (nothing unpushed)
gh pr list --state open --json number,title,headRefName
```

- Not on `main`: **stop**, tell the user to `git switch main` first. A release describes `main`.
- Dirty tree: **stop**, and tell the user:
  > You have uncommitted changes. Run `/commit` to land them (or `git stash` to set them
  > aside), then rerun `/release`. I will not fold unrelated work into a release commit.
- An open PR whose branch starts with `chore/release-`: **stop**, that bump is already in
  flight. Point at it and ask the human to merge it, then rerun `/release` for Phase B.
- Other open PRs are fine. Mention them, since anything unmerged will not be in this release.

## Step 2 — Derive the bump, then let the argument override it

Read what actually changed:

```bash
git log "$LATEST_TAG..origin/main" --format='%h %s'
git diff --stat "$LATEST_TAG..origin/main"
```

Classify by Conventional Commit type, then **apply judgement on top**:

| Evidence | Bump |
| --- | --- |
| any `feat` | minor |
| only `fix`, `perf`, `refactor`, `docs`, `ci`, `chore`, `build`, `style`, `test` | patch |
| a `fix` that changes a documented contract, removes a setting, or migrates stored state | minor, and say why |
| `!` after the type, or `BREAKING CHANGE` in a body | **never automatic**, see below |

The type prefix is evidence, not the verdict. Nothing validates PR titles in CI, and squash
merges take their subject from the PR title, so a mislabelled commit is normal. Read the diff
when a subject looks thinner or larger than its prefix claims.

While the version is `0.x`, a minor bump means `0.(minor+1).0`. Semver puts no stability
promise on `0.x`, so do not agonise: a `feat` is a minor.

Now resolve `$ARGUMENTS`:

| Input | Action |
| --- | --- |
| Empty | Propose the derived bump with the evidence, and ask for confirmation |
| Contains `patch`, `minor` or `major` anywhere (`/release major release` counts) | Use it. If it disagrees with the derivation, use the argument and say plainly what the derivation said |
| Looks like `X.Y.Z` | Use it verbatim, after checking it is strictly newer than `$LATEST_TAG` |
| Contains `--dry-run` | Report the derivation, the target version, and Step 3's screening, then **stop without changing anything** |

**Never derive a major bump.** A `!` or `BREAKING CHANGE` makes you *report* that and ask;
only the literal word `major` in the argument selects it. Also refuse a version that is not
`^[0-9]+(\.[0-9]+)*$`: the in-app update check (`UpdateCheck.swift`) ignores anything else, so
a version like `0.2.0-rc1` would publish and then be invisible in Settings › About.

## Step 3 — Screen what the release will say about us

The workflow publishes with `--generate-notes`, which inlines **every merged PR title since
the last tag, verbatim**, into the release body, the Releases feed and watcher emails. CLAUDE.md
names auto-generated release notes as the case that is hardest to correct afterwards.

So read the subjects from Step 2 against that rule: no client or ticket substance, no named
third parties, no absolute home directories. If one is a problem, **stop and tell the human**
which title and why. A PR title cannot be rewritten retroactively into a published feed, so
this is the last moment it is cheap.

Also confirm the README's pictures are current: if this release changed anything
`scripts/make-docs-images.sh` renders, that regeneration belongs in a normal PR before the
bump, not in the release commit.

## Step 4 — Land the bump as a PR, then stop

```bash
git switch -c "chore/release-v$NEW"
printf '%s\n' "$NEW" > VERSION
```

Write the commit message to a file and use `-F` (prose with backticks or `$` gets mangled when
passed inline, which has already eaten a commit message in this repo):

```bash
git add VERSION
git commit -F <message-file>          # chore(release): v$NEW
git push -u origin "HEAD:refs/heads/chore/release-v$NEW"
gh pr create --base main --title "chore(release): v$NEW" --body-file <body-file>
```

The PR body carries the derived changelog: the bump and why, the commits grouped by type, and
a note that merging publishes nothing by itself. Do not delegate this to `/pr-open`: the body
is the derivation you just did, not a generic summary.

Then **stop**. Tell the human:

> `chore(release): v$NEW` is open at <url>. Merge it once CI is green, then run `/release`
> again and I will tag the merge commit. Merging alone publishes nothing.

You never merge it. `gh pr merge` is forbidden here and blocked by a hook.

## Step 5 — Pre-flight the exact commit you are about to tag

Phase B. The tag is the point of no return, so verify against the **commit**, not the working
tree. `SHA` is the tip of `origin/main`.

```bash
SHA=$(git rev-parse origin/main)
git show "$SHA:VERSION"                       # must equal $DECLARED, no leading v
git merge-base --is-ancestor "$SHA" origin/main
gh run list --commit "$SHA" --workflow ci.yml --limit 1     # must be success
gh release view "v$DECLARED" 2>&1 | head -1                 # must be a 404
git ls-tree "$SHA" integrations/agent-tracker-hook.py       # must show mode 100755
make lint && make test
```

Every one of these mirrors a guard in `release.yml` that would otherwise fail the run, except
the last two, which fail `make app` inside it (the bundle build asserts the hook script is
executable) and lint, which `release.yml` does not run at all. `ci.yml` is the only lint gate,
which is why its run on this exact commit has to be green.

Two more that the release itself will not tell you:

```bash
gh secret list                          # signing 0-of-3 or 3-of-3; notary likewise
gh workflow run tap-access.yml          # then wait for it green
```

Notarization needs the signing secrets, and the workflow refuses a partial set of either
group. The tap check is the **only** pre-release signal that `TAP_GITHUB_TOKEN` still works,
because a dead token degrades the cask update to a printed warning instead of failing.

Report what the run will produce given the secrets that exist: ad-hoc signed, Developer ID
signed, or signed and notarized. Do not assert which from memory, read it from `gh secret list`.

## Step 6 — Tag it

```bash
git tag -a "v$DECLARED" -F <tag-message-file> "$SHA"
git push origin "v$DECLARED"
```

Use exactly that push form. `git push origin refs/tags/...` and `git push --tags` are both
blocked by the repo's guard hook, and neither `git tag` nor `git push` is pre-approved, so
expect a permission prompt. Never `gh api` a ref into existence to get around it: the point of
the guard is that this boundary is deliberate.

## Step 7 — Watch the run, then verify what shipped

```bash
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Green is not proof the release is correct. Verify the artifact against its own advertised
digest, because a mismatch has shipped before:

```bash
gh release download "v$DECLARED" --dir "$tmp" --pattern 'AgentTracker-*.zip'
shasum -a 256 "$tmp"/AgentTracker-*.zip                       # compare with the notes body
gh release view "v$DECLARED" --json body --jq .body | grep -oE '[0-9a-f]{64}'
gh api repos/ThinkVelta/homebrew-tap/contents/Casks/agent-tracker.rb \
  --jq .content | base64 -d | grep -E '^  (version|sha256)'
```

The cask must show the new version **and** the same digest. The tap step cannot fail the
release by design, so a green run does not mean the cask moved. If it did not, the run's
annotations print the two values to set, and someone applies them by hand.

## Step 8 — Report back

State the version, the tagged SHA, whether the build was notarized, the release URL, the
verified digest, and the cask's state. Then say what a user upgrading will experience, taken
from the notes the workflow actually produced rather than from assumption.

## When something fails

- **Before "Publish the release"**: nothing is public. Fix the cause. If the fix is a code
  change the tag must move, and deleting a remote tag is blocked here, so ask the human to
  delete it or roll the version forward. If nothing needs to change, `gh run rerun` is enough.
- **After the release is published**: the version number is spent. The digest cannot be
  reproduced (the bundle carries a commit count and a signing timestamp), watchers were already
  notified, and every installed copy is already advertising it through the update check. The
  correct recovery is always **bump to the next patch and release again**, never delete and
  redo the same version.

## Important rules

Re-stated because a release is exactly where "just this once" is most tempting.

- **You never merge and never push to `main`.** Both are blocked mechanically. The `VERSION`
  bump reaches `main` the same way every other change does.
- **The tag is the release.** Treat pushing it as the irreversible act, and do the verifying
  before it rather than after.
- **Never reuse a published version number**, even if the release looked wrong seconds later.
- **Read state, do not remember it.** Which half you are in, whether a tag exists, whether the
  build was notarized: all of it is observable, and all of it has been wrong when assumed.
