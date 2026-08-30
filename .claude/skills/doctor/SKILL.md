---
name: doctor
description: Run Agent Tracker's --doctor, explain every finding, and investigate registry format drift against the Claude Code binary. Use when the app misbehaves — wrong or missing session names, rows in the wrong group, click-to-focus failing — or after upgrading Claude Code. Triggers for `/doctor`.
allowed-tools:
  - Bash
  - Read
  - Grep
---

# Doctor

Run the app's own diagnostic, then do the part it cannot: explain what a finding
means, and — when Claude Code has started writing a value this build does not
know — work out what that value *is* by reading the binary that writes it.

**Read-only, start to finish.** `--doctor` never writes, installs, grants or
prompts, and neither does this. Change nothing; report, and propose.

## Step 1 — Pick the binary, and say which one you ran

Two builds can disagree, so name the one you used. Prefer the **installed app**,
because that is what the user is actually running:

```bash
ls /Applications/AgentTracker.app/Contents/MacOS/AgentTracker 2>/dev/null
defaults read /Applications/AgentTracker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null
git -C . rev-parse --show-toplevel 2>/dev/null
```

- Installed app present → `/Applications/AgentTracker.app/Contents/MacOS/AgentTracker --doctor`
- Otherwise, inside the repo → `swift run AgentTracker --doctor`

Never `open -a`: the app is menu-bar-only, so `open` sends stdout nowhere and
you will report an empty run as a clean one.

**Run it from the directory the user is having trouble with**, not from `$HOME`.
One check walks up from the working directory looking for a project-level
`statusLine`; from elsewhere it has nothing to find. The report prints which
directory it searched — quote that line if the user's problem is about usage or
context numbers.

If the installed app predates the check you are looking for, say so rather than
concluding from its absence. `registry format` first shipped after v0.12.1.

## Step 2 — Read the report, do not just paste it

Exit status is 0 when nothing failed, 1 when something did. Warnings never fail.

Group what you found:

- **`FAIL`** → the install is broken. Name the fix (`./install.sh`, usually) and
  the `docs/troubleshooting.md` section the finding cites.
- **`WARN`** → worth knowing, not broken. Say which ones are expected on this
  machine — no statusline wrapper is a choice, stale sessions are normal while
  the app is not running — and which are not.
- **`?`** → the check could not run. This is not evidence of a problem. Say what
  would make it answerable.

Every finding that has a `docs/troubleshooting.md` anchor prints it. Read that
section before explaining the finding in your own words; do not invent a cause
the page already names.

## Step 3 — `registry format` drift: investigate, do not just relay

This is the finding worth a skill. It reads like:

```text
WARN  registry format  Claude writes value(s) this build does not know: nameSource "sponsor"
```

It means Claude Code now writes a value in `~/.claude/sessions/<pid>.json` that
this build has no case for. The app degrades quietly on one — an unknown
`nameSource` is treated as a name Claude invented, so a name the **user** chose
may stop appearing; an unknown `status` expresses no opinion, so a session may
sit in the wrong group. The check says a new value exists. It cannot say what it
*means*. That is this step.

### 3a. Confirm it on disk, and get the version that wrote it

```bash
claude --version
grep -hoE '"(nameSource|status)":"[^"]*"' ~/.claude/sessions/*.json | sort -u
```

### 3b. Read the binary that writes it

The fields are undocumented and no release note mentions them, so the binary is
the only authority. Locate it — a version bundle, not the launcher shim:

```bash
ls -la ~/.local/share/claude/versions/ 2>/dev/null
which claude
```

Then search it. **Narrow the match**, or you will pull hundreds of KB into
context for nothing — a plain `grep nameSource` over a 200 MB binary is
unreadable:

```bash
strings -a ~/.local/share/claude/versions/<version> | grep -o '.\{200\}<token>.\{300\}' | head -20
```

Look for two different things, because they answer different questions:

1. **The normalizer** — the expression listing every accepted value, shaped like
   `x==="user"||x==="peer"||…?x:void 0`. This is the complete vocabulary, and it
   tells you whether the new token is one Claude keeps or one it discards.
2. **The writer** — where the value is set. A default parameter (`r="user"`)
   says what an action now writes where it once wrote nothing, which is exactly
   the class of change that broke v0.12.0.
3. **The consumer** — how Claude itself *displays* the field. If Claude prints a
   name for a set of sources, that set is the rule this app should mirror, and
   mirroring it beats inventing a parallel one.

### 3c. Say what it means for this app, concretely

Map the finding onto behavior the user can see, and check the current rule:

```bash
grep -n "knownNameSources\|chosenNameSources\|case busy" Sources/AgentTracker/RegistryContract.swift Sources/AgentTracker/ClaudeSessionRegistry.swift
```

Then state, plainly:

- what the new value is, and what Claude uses it for
- whether this app currently reads it right, wrong, or merely unknown
- which rows the user would see behaving oddly, if any

If a code change is warranted, **describe it and stop**. Adding a case to
`RegistryContract` or `Status` is a normal `fix:` branch off `dev` with a test —
propose it, and let the user say go. Do not edit from inside a diagnostic.

If the value turns out to be one Claude discards too, or is used for something
this app never reads, say so — "a new token exists and it does not affect us" is
a complete and useful answer.

## Step 4 — Report

Lead with the verdict, not the transcript:

```text
doctor — <healthy | N problem(s) | drift found>

  Ran:      <which binary, which version, from which directory>
  Failures: <each, with the fix>
  Warnings: <the ones that are not expected on this machine>
  Drift:    <the new value, what it means, whether we read it correctly>
```

Paste the raw report only if the user asks, or if a line is doing work your
summary cannot. Never claim "no problems found" above a check that could not
run — say what did not answer, the same way the report itself does.

## Limits, state them when relevant

The drift check is a smoke alarm, not a proof: it only sees values the sessions
on **this** machine happen to produce, so a token that appears only for, say, a
peer session stays invisible until one runs. Silence means nothing unfamiliar
turned up, never that the format is unchanged. Say this if the user reads a
clean `registry format` line as a guarantee.

`--doctor` also deliberately skips the Ghostty Automation grant: querying it can
block for over a minute even without prompting. Its absence from the report is
by design, not a gap to work around here.
