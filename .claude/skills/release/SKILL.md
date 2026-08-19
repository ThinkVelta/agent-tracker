---
name: release
description: Cut a release. Derives the version bump from the commits since the last tag, lands the VERSION bump into dev as a PR, promotes dev to main as a second PR, then tags the merge commit and verifies what actually shipped. Use this when the user wants to publish a version, cut a release, or ship what is on dev. Triggers for `/release`, `/release patch|minor|major`, `/release 0.3.0`, `/release --dry-run`.
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

Releasing takes **three** invocations, because two PRs have to be merged by a human and you
cannot merge either:

| Phase | What you do | What the human does |
| --- | --- | --- |
| **A** | Derive the bump, open `chore/release-vX.Y.Z -> dev` | Merges it |
| **B** | Open `dev -> main` | Merges it |
| **C** | Pre-flight `main`, push the tag, verify what shipped | Nothing |

Do not try to collapse them, and in particular do not try to put the bump straight onto a
branch aimed at `main`: everything must reach `main` through `dev`, so that the two branches hold
the same **tree** the moment a release lands.

The same tree, not the same commit. Measured after v0.3.0, the first release through this flow:
merging the promotion PR leaves `main` one merge commit ahead of `dev`, and one more after every
release. `git diff origin/dev origin/main` is empty; `git rev-parse` of the two is not. So the
check that means anything is **`git rev-list --count origin/main..origin/dev`** — nonzero means
`dev` carries work that has not been released. Comparing the two SHAs would report a difference
after every single release and mean nothing by it.

Work out which phase you are in from the repo's state (Step 0) rather than from memory, so an
interrupted release resumes correctly.

The reason this is a skill and not CI: **choosing the bump is a judgement call**, and a
published release cannot be taken back. You read what changed and propose a version; the human
approves it.

**User input:** $ARGUMENTS

## Step 0 — Work out which phase you are in

```bash
git fetch --tags origin main dev
ON_MAIN=$(git show origin/main:VERSION | tr -d '[:space:]')    # what has been released
ON_DEV=$(git show origin/dev:VERSION | tr -d '[:space:]')      # what is being prepared
LATEST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
git ls-remote --tags origin "refs/tags/v$ON_MAIN"              # empty means unreleased
gh release view "v$ON_MAIN" --json tagName --jq .tagName 2>/dev/null || echo "not published"
```

Read the phase off those three values, in this order — the first match wins:

| State | Phase | Continue at |
| --- | --- | --- |
| `v$ON_MAIN` does not exist as a tag or release | **C**, tag it | Step 1, then Step 6, releasing `$ON_MAIN` |
| `$ON_DEV` differs from `$ON_MAIN` | **B**, promote | Step 1, then Step 5, promoting `$ON_DEV` |
| otherwise | **A**, prepare the bump | Step 1, then Step 2 |

The order matters, and C comes first for a reason: between B's merge and C's tag, `main` and
`dev` declare the *same* new version, so the "differs" test alone would send you back to B and
open a second, empty promotion PR.

**Step 1 applies to every phase.** C validates and then tags, and neither is meaningful against
a tree that is not the commit being released.

If Phase C and you did not prepare that bump yourself, say so and show the human the diff of
`VERSION` and who landed it before going further. A stray bump in an unrelated PR is the one
way to reach Phase C by accident.

## Step 1 — Refuse to start from an unclear place

All of these, before touching anything:

Each phase works from a different branch, because each describes a different thing: A and B
describe `dev` (what is being released), C describes `main` (what is being tagged).

```bash
git branch --show-current                # A and B: dev.  C: main
git status --porcelain                   # must be empty, no exceptions
git rev-parse HEAD "origin/$(git branch --show-current)"   # equal; behind is fixable
gh pr list --state open --json number,title,headRefName,baseRefName
```

- Dirty tree: **stop**, and tell the user:
  > You have uncommitted changes. Run `/commit` to land them (or `git stash` to set them
  > aside), then rerun `/release`. I will not fold unrelated work into a release commit.
- **On the wrong branch, with one exception**: **stop** and tell the user to switch to the
  branch this phase describes. The exception is the position each phase naturally leaves you
  in — a clean tree on the `chore/release-vX.Y.Z` branch after A, or on `dev` after B. Moving
  from there to the branch the next phase needs is mechanical rather than a decision, so just do
  it (`git switch`, `git pull --ff-only`, and delete the merged release branch). What the gate
  protects is uncommitted work and releasing from a feature branch, and neither is in play.
- `HEAD` behind its remote: expected whenever the previous phase's PR merged after your last
  fetch, so `git pull --ff-only` and carry on. **Ahead means stop**, on either branch: you
  cannot push to `dev` or `main`, so a local commit ahead of them is work that would silently
  not be in the release.
- An open PR whose branch starts with `chore/release-`: in Phase A, **stop**, that bump is
  already in flight, so point at it and ask the human to merge it. Later phases should not see
  one at all, so if one is still open, say so rather than releasing around it.
- An open `dev -> main` PR: in Phase B, **stop** — that promotion is already open, so point at
  it. In C it should have merged, so an open one means the tip of `main` is not what you think.
- Other open PRs are fine. Mention them, since anything unmerged will not be in this release.

Step 1 ends with a clean tree at the tip of the branch this phase describes. For Phase C that
end state is what makes `HEAD` **be** the commit you are about to tag, which is what lets Step 6
validate it by running the suite here rather than in a scratch checkout.

## Step 2 — Derive the bump, then let the argument override it

Read what actually changed:

```bash
git log "$LATEST_TAG..origin/dev" --format='%h %s'
git diff --stat "$LATEST_TAG..origin/dev"
```

`origin/dev`, not `origin/main`: the work is on `dev` and has not reached `main` yet, so
deriving from `main` would read the *previous* release and propose no bump at all.

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

## Step 4 — Phase A: land the bump into `dev`, then stop

Branch from `dev`, which Step 1 has already left you on and up to date.

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
gh pr create --base dev --title "chore(release): v$NEW" --body-file <body-file>
```

The PR body carries the derived changelog: the bump and why, the commits grouped by type, and
a note that merging publishes nothing by itself. Do not delegate this to `/pr-open`: the body
is the derivation you just did, not a generic summary.

Then **stop**. Tell the human:

> `chore(release): v$NEW` is open at <url>, into `dev`. Merge it once CI is green, then run
> `/release` again and I will open the `dev -> main` promotion. Merging alone publishes nothing.

You never merge it. `gh pr merge` is forbidden here and blocked by a hook.

## Step 5 — Phase B: open `dev -> main`, then stop

The bump is on `dev` and `main` is still the previous release. One PR moves everything across:

```bash
gh pr create --base main --head dev \
  --title "chore(release): promote v$ON_DEV to main" --body-file <body-file>
```

No branch to create and nothing to commit — `dev` is the head. If `gh` reports no commits
between the branches, `main` is already at `dev` and you are in Phase C, not B; re-read Step 0
rather than forcing this PR.

The body is the same changelog Step 2 derived, plus the two things only this PR can say: that
merging it moves `main` without publishing anything, and that the tag follows on the next
`/release`. The AI reviewer is deliberately skipped on this PR (`pr.yml` skips a head of `dev`)
because every commit in it has already been reviewed once on the way into `dev` — say so in the
body, so nobody reads the missing status as a broken check.

Then **stop**. Tell the human:

> `dev -> main` is open at <url>, carrying v$ON_DEV. Merge it once CI is green, then run
> `/release` a third time and I will tag the merge commit. Merging alone publishes nothing.

## Step 6 — Phase C: pre-flight the exact commit you are about to tag

Phase C. The tag is the point of no return, so every check has to describe the **commit** being
tagged: the tip of `origin/main`, which is the promotion's merge commit and not `dev`'s tip.
The two point at the same tree, but the tag has to name the commit that is actually on `main`,
because `release.yml` refuses one that is not.

```bash
SHA=$(git rev-parse origin/main)
test "$(git rev-parse HEAD)" = "$SHA" && test -z "$(git status --porcelain)"
git show "$SHA:VERSION"                       # must equal $ON_MAIN, no leading v
git merge-base --is-ancestor "$SHA" origin/main
gh run list --commit "$SHA" --workflow ci.yml --limit 1     # must be success
gh release view "v$ON_MAIN" 2>&1 | head -1                  # must be a 404
git ls-tree "$SHA" integrations/agent-tracker-hook.py       # must show mode 100755
make lint && make test
```

The first line is load-bearing, not a formality. `make lint` and `make test` run against the
working tree, so they only say anything about `$SHA` while the tree *is* `$SHA`. Step 1 should
have established that already; assert it again here, because this is the last check before an
irreversible act and Step 1 may have run minutes ago. If it fails, fix the tree rather than
reasoning about which files differ.

If the human genuinely cannot clean the tree, validate in a scratch checkout instead of
skipping it: `git worktree add --detach "$tmp" "$SHA"`, run `make lint && make test` in there,
then `git worktree remove "$tmp"`. Slower, and it still leaves the tag push needing a clean
`main`, so prefer fixing the tree.

The other checks each mirror a guard in `release.yml` that would otherwise fail the run, except
the mode bit, which fails `make app` inside it (the bundle build asserts the hook script is
executable), and lint, which `release.yml` does not run at all. `ci.yml` is the only lint gate,
which is why its run on this exact commit has to be green.

**What `release-pr.yml` already checked, and why these are still here.** That workflow ran on
both release PRs and asserted the same three things about `VERSION`: dotted integers, not
already tagged, and newer than the latest published release by the app's own comparison. It
also asserted that the bump PR changed nothing but `VERSION`, and that the promotion changed
`VERSION` at all — neither of which this step can see, so those are genuinely delegated and are
not repeated here. The version checks are repeated, deliberately: CI answered them about a PR
head, and this answers them about the commit the tag will name, which is a different commit
whenever anything merged in between.

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

## Step 7 — Tag it

```bash
git tag -a "v$ON_MAIN" -F <tag-message-file> "$SHA"
git push origin "v$ON_MAIN"
```

Use exactly that push form. `git push origin refs/tags/...` and `git push --tags` are both
blocked by the repo's guard hook, and neither `git tag` nor `git push` is pre-approved, so
expect a permission prompt. Never `gh api` a ref into existence to get around it: the point of
the guard is that this boundary is deliberate.

## Step 8 — Watch the run, then verify what shipped

```bash
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Green is not proof the release is correct. Verify the artifact against its own advertised
digest, because a mismatch has shipped before:

```bash
gh release download "v$ON_MAIN" --dir "$tmp" --pattern 'AgentTracker-*.zip'
shasum -a 256 "$tmp"/AgentTracker-*.zip                       # compare with the notes body
gh release view "v$ON_MAIN" --json body --jq .body | grep -oE '[0-9a-f]{64}'
gh api repos/ThinkVelta/homebrew-tap/contents/Casks/agent-tracker.rb \
  --jq .content | base64 -d | grep -E '^  (version|sha256)'
```

The cask must show the new version **and** the same digest. The tap step cannot fail the
release by design, so a green run does not mean the cask moved. If it did not, the run's
annotations print the two values to set, and someone applies them by hand.

## Step 9 — Report back

State the version, the tagged SHA, whether the build was notarized, the release URL, the
verified digest, and the cask's state. Then say what a user upgrading will experience, taken
from the notes the workflow actually produced rather than from assumption.

## When something fails

- **Before "Publish the release"**: nothing is public. Fix the cause. If the fix is a code
  change the tag must move, and deleting a remote tag is blocked here, so ask the human to
  delete it or roll the version forward. If nothing needs to change, `gh run rerun` is enough.
- **Notarization timed out**: also nothing public, and usually nothing wrong — a team's
  **first-ever submission** goes through extended vetting (measured: ~95 minutes on v0.3.1)
  while every later one takes minutes. Do not resubmit into the queue: the run's log names the
  submission id, so poll `xcrun notarytool info <id>` until it concludes, then
  `gh run rerun <run-id> --failed` — the rerun's fresh submission rides the now-vetted fast
  lane. If a team's first notarization is still ahead of you, bootstrap it with a throwaway
  local submission *before* tagging, so no release run ever waits on the slow lane.
- **After the release is published**: the version number is spent. The digest cannot be
  reproduced (the bundle carries a commit count and a signing timestamp), watchers were already
  notified, and every installed copy is already advertising it through the update check. The
  correct recovery is always **bump to the next patch and release again**, never delete and
  redo the same version.

## Important rules

Re-stated because a release is exactly where "just this once" is most tempting.

- **You never merge, and never push to `main` or `dev`.** All of it is blocked mechanically.
  The `VERSION` bump reaches `main` the same way every other change does: through `dev`, through
  a PR, merged by a human.
- **The tag is the release.** Treat pushing it as the irreversible act, and do the verifying
  before it rather than after.
- **Never reuse a published version number**, even if the release looked wrong seconds later.
- **Read state, do not remember it.** Which phase you are in, whether a tag exists, whether the
  build was notarized: all of it is observable, and all of it has been wrong when assumed.
