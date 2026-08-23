# Agent Tracker documentation

For people who have already installed it and hit something. The
[project README](../README.md) is the tour and the install guide.

| Page | Read it when |
| --- | --- |
| [Troubleshooting](troubleshooting.md) | something is not showing up, or is showing the wrong thing |
| [The statusline wrapper](statusline.md) | you want usage numbers, context readings, or exact window matching |
| [Scheduled continues](scheduled-continues.md) | a session refused to resume itself, or you want to know what it will refuse |
| [Permissions](permissions.md) | click-to-focus does nothing, or a write into a terminal was refused |
| [Uninstalling](uninstall.md) | you want it gone, or want to know what it touched |
| [How it works](architecture.md) | you want to know what is on disk and what reads it |

## Before reading any of it

```sh
/Applications/AgentTracker.app/Contents/MacOS/AgentTracker --doctor
```

Checks the mechanical half of the troubleshooting page, and names the section
explaining a finding where there is one. Read-only, never prompts, safe to run
unasked. Run it from the project you are having trouble with; one check looks
upward from the working directory.

## The three answers that come up most

**Sessions that were already running when you installed do not appear.** Claude
Code reads its hook configuration at session start, so they never report
anything. Restart them.

**A blank context reading or a missing usage number means "not told", not
"zero".** Both come only from Claude's statusline payload, so both need the
[statusline wrapper](statusline.md). The app leaves them blank rather than
showing zero, on purpose: "plenty of room" and "nothing known" must not look
alike.

**Two sessions in one repo look identical because they are, to everything the app
can see.** Give one a name (`/rename billing spike` in its terminal) and it
becomes addressable, because the name Claude sets is exactly what window matching
compares.

## Reading this as an agent

Facts here are written to be quotable on their own rather than positionally, so a
retrieved paragraph does not depend on the one above it. Where a claim is
checkable, the command to check it is given rather than described.

Two things to reach for before reading prose. `--doctor` reports the state of
the install, citing a section where one applies; the log records what the app
decided and why:

```sh
/Applications/AgentTracker.app/Contents/MacOS/AgentTracker --doctor
tail -50 ~/.agent-tracker/logs/agent-tracker.log
```

`--doctor` exits 0 when nothing failed and 1 when something did, so it composes
with `&&`.
