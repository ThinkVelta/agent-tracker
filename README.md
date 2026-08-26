<div align="center">

<img src="assets/icon.png" alt="" width="120">

# Agent Tracker

**Know which Claude Code session needs you, without hunting through terminals.**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://github.com/ThinkVelta/agent-tracker/releases/latest)
[![Download](https://img.shields.io/badge/download-latest%20release-2ea44f)](https://github.com/ThinkVelta/agent-tracker/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/dropdown-dark.png">
  <img alt="The dropdown, listing sessions grouped by state" src="assets/dropdown-light.png" width="380">
</picture>

</div>

## Why

Run more than one Claude Code session and the same question keeps coming back:
*which one is waiting on me?* Answering it means cycling through terminal
windows across Spaces, and the answer goes stale while you look.

Agent Tracker keeps it in your menu bar. Three dots, three counts:

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/menubar-dark.png">
  <img alt="Menu bar icon: 2 red, 2 green, 1 grey" src="assets/menubar-light.png" width="120">
</picture>
</div>

- 🔴 **Needs you**: the turn finished, or it wants permission
- 🟢 **Running**: working right now
- ⚪ **Idle**: open, nothing pending

**Click a row and you land in that terminal**, across Spaces, and the session
stops asking for attention. Click a *dot* to open the list already filtered to
that state. Visit a session's terminal yourself and it clears on its own after a
few seconds.

No daemon, no telemetry, no account. Claude Code reports through the hooks it
already supports, and the app reads plain JSON off disk.

Already installed and something is off? Run
`/Applications/AgentTracker.app/Contents/MacOS/AgentTracker --doctor`, which
checks the install and points at what to read. Or start from
**[Troubleshooting](docs/troubleshooting.md)** or the
[documentation index](docs/README.md).

## Install

Requirements: macOS 14 or later. Releases are Developer ID signed and
notarized by Apple, so the first launch opens without any Gatekeeper dialog.

[**Download the latest release**](https://github.com/ThinkVelta/agent-tracker/releases/latest),
unzip it, and drag **AgentTracker.app** to `/Applications`.

Or install through Homebrew:

```sh
brew tap ThinkVelta/tap
brew trust --cask thinkvelta/tap/agent-tracker
brew install --cask agent-tracker
```

Homebrew 6 refuses to load casks from taps outside its own repositories until
you trust them. Without the middle line the install stops with *"Refusing to
load cask … from untrusted tap"*. That applies to every third-party tap, and
trusting is per-machine.

Trusting the single cask rather than the tap is deliberate. `brew trust
thinkvelta/tap` also works, but it covers everything added to the tap in
future, including casks that do not exist yet.

Either way, launch it. A first-run window walks you through granting
Accessibility, connecting Claude Code, and starting at login.

> [!NOTE]
> Releases before v0.3.1 were not notarized. If you install one of those older
> zips, macOS blocks the first launch with *"AgentTracker Not Opened"* and
> highlights **Move to Trash**. Click **Done** instead, then allow the app
> under **System Settings › Privacy & Security › Open Anyway**.

The app checks for newer releases once at launch and once a day. Finding one
shows a line in the dropdown, and posts a notification when banners are
allowed. That check is a single request to the GitHub
releases API and the only unprompted network activity in the app; Settings ›
About turns it off, houses the manual check, and offers the install. Nothing
installs without you. Installing by hand verifies the release's own digest and
the Developer ID signature before swapping the app; you can also opt in to
installing automatically at launch. A Homebrew install is recognized and
updated through `brew upgrade`, from the same button.

Agent Tracker asks for up to three macOS permissions (Accessibility for
click-to-focus, Automation for renaming a session in a Ghostty window,
Notifications for banners), and none of them is needed just to watch sessions.
See **[permissions](docs/permissions.md)**, which covers which ones you will
actually be asked for, plus one thing that is not obvious. A lost
Accessibility grant is fixed by *removing and re-adding* the entry, never by
toggling it.

## What you get

**Click-to-focus.** The row you click raises that session's terminal window,
switching Spaces if it lives on another one, matched by the window's live
working directory and title, via the Accessibility API.

**Per-dot filtering.** Clicking the red dot opens the list showing only what
needs you. Clicking it again closes it. The chips at the top of the dropdown do
the same thing.

**A stuck background shell is called out.** A turn that ended with a shell
still running shows as running, because Claude resumes it when the shell ends.
One that has run for half an hour without waking the session goes red for the
shell instead, and its row can end it, which wakes Claude with the output so
far. The threshold is in Settings › Sessions.

**A menu bar that stays out of the way.** Four icon modes, from counts on every
dot down to a single dot that appears only when something needs you, each of
them available in monochrome, which takes the menu bar's tint like a system
icon and tells the states apart by shape:

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/icon-modes-dark.png">
  <img alt="The available menu bar icon modes" src="assets/icon-modes-light.png" width="420">
</picture>
</div>

**Quota, before it stops you.** A strip above the footer shows both windows,
`5h 38%   7d 49%`, so the number that decides whether to start something big
is readable at a glance rather than discovered when a request is refused. Both,
because they answer different questions: the 5-hour one is *can I start this
now*, the weekly one is *how much of this week is left*. They stay in that
order whatever the numbers do, so the one you want is always in the same place.
Grey until 75%, amber to 90%, red past it; hover for the reset time. A window
shows only when a reading exists, because "nothing known" and "nothing used" are
not the same thing. Needs the statusline wrapper (below).

**Name a session and the row says so.** Run `/rename billing spike` in Claude
Code and the row takes that name. Claude owns the rename, so its terminal
tab title follows too, and this app just reads what Claude recorded. Nothing to
configure.

**Or rename it from the app, which asks Claude to do it.** Right-click a row,
*Rename…*, and the app types `/rename` into that session's own terminal. It does
deliberately not keep a nickname of its own. There is one name, Claude's,
and the app reads it back like any other. So renaming here and renaming there cannot
drift apart, and the terminal tab follows either way.

It can be turned down, which a private label never could. A rename is typed into
a live session, so the app refuses one that is not sitting at a finished
turn, because pressing Return at an open permission prompt would answer it. Outside tmux it
also has to know which window is yours, and the sessions it cannot tell apart
are the ones sharing a title with a sibling, which is exactly what renaming one
would fix. When that happens it says so and points at `/rename` in the terminal,
which has no such limit.

**And two sessions in one repo stop looking identical.** Rows are otherwise
titled by project, which is right until two of them share one. Then the list
shows the same word twice and the only way to tell which is which is to click
one and find out. Claude also derives a name for every session
(`api-gateway-02`), so an ambiguous row wears that. Only an ambiguous one: a
generated name on every row would be noise on the majority of lists, which have
no duplicate at all. A name *you* chose is always shown, because suppressing it
would be the app overruling you about your own session. Either kind is
searchable.

**Context pressure, shown quietly until it is pressure.** Every row *with a
reading* says how full its context window is. Below 70% the number is set
exactly like the timestamp beside it and recedes into the line; past 70% it
takes weight and turns amber, and red past 90%. So a glance costs nothing and
still tells you which session is running out of room, and a row with no
reading at all stays blank rather than showing a zero, so "plenty left" and "nothing
known" never look the same. It sits in its own slot rather than in the row's
metadata line, because that line truncates and this is precisely the number you
would not want cut. The reading arrives once that session's statusline has
rendered, which needs the statusline wrapper (below).

**A banner, if you want one.** Off by default: the menu bar is the passive
channel this app was built to be, and a notification is the most intrusive thing
it can do. Switch it on in Settings › Sessions and a session flipping to
needs-you posts one banner naming the project, the agent, and what it is
waiting for, which takes you to that terminal when clicked, exactly as clicking the row does.
It announces the flip and not the state, so a session waiting at a prompt is one
banner rather than one a second; going to the terminal yourself withdraws it
again. Focus and Do Not Disturb hold these back like any other app's, which is
the point of not marking them time-sensitive.

**Group by project when that is the question.** Sections divide by state by
default, because the app's question is *which one needs me*. Settings › General
switches them to project, which is what you want once several sessions live in
one repo and the state grouping scatters them across three headings. A project
takes the most urgent state inside it, for its dot and for its place in the
list, so a repo holding something that needs you still leads, and cannot read
as calm.

**Pin the one you are watching.** A pinned session sits in its own group at the
top of the list whatever it is doing, so it stops moving between sections while
you are looking at it. Right-click a row and choose *Pin to top*. It leaves its
state section rather than appearing twice, and the dot counts are unchanged: a
pinned needs-you session is still one of the red ones. The group has no collapse
chevron, because hiding what you asked to keep visible is not a thing to offer.

**Row actions, on right-click.** *Mute* is for the long-running background
agent that finishes a turn every few minutes: it is doing exactly what it
should, and every completion turns the menu bar red for something you never
intended to look at. A muted session displays as idle and keeps the reason it
gave, so the row still reads `Muted · Claude · api-gateway · Approve Bash?`.
It says what it wants, it just does not pull you. Counts, sections and
notifications all follow, because they read the state. The mute lasts as long as
the session does; the next session in that directory has not asked to be
ignored. *Copy resume command* puts `claude --resume <id>` on the clipboard,
which is what you want once a session has ended and you would like it back.

## How it works

No daemon. Claude Code pushes events through its native hook mechanism; a
dependency-free Python script turns each one into a per-session JSON file, and
the app watches those files. Dead sessions are pruned by pid, so a killed
terminal disappears without a clean exit.

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/architecture-dark.png">
  <img alt="Claude Code writes state files; Agent Tracker watches them; you get a menu bar icon, a session list and click-to-focus" src="assets/architecture-light.png" width="700">
</picture>
</div>

**[How it works, in full](docs/architecture.md)** covers what is on disk,
how click-to-focus matches a window, why a finished turn is not always "needs you",
and how writing into a terminal is gated.

## Known limitations

- **Several sessions in one repo look alike, and clicking one may open its
  sibling.** They share a directory, so they get the same row title, and their
  terminals report nothing that tells them apart. Clicking is better than a coin
  flip: the rows are spread across the candidate windows rather than all pointing
  at the first, and clicking again walks the rest, so two rows normally open two
  terminals. What is *not* guaranteed is that each one opens its own. Ghostty
  exposes no per-window identity that would settle it, and `WindowIdentity`
  documents the four routes that were tried and closed. **Naming one of them
  fixes it**; see [troubleshooting](docs/troubleshooting.md).
- **Usage numbers and context readings need the statusline payload.** The
  usage strip reads `rate_limits` and the per-row percentage reads
  `context_window`. The payload reaches the app only through the
  [statusline wrapper](docs/statusline.md) or your own script dumping it, so
  without one the app says it cannot tell rather than claiming you have room
  left. Session names travel separately, through `~/.claude/sessions/`, so
  rows and window matching keep their names either way.

## Build from source

Requirements: the above, plus a Swift toolchain (Xcode or CLT) and Python 3.

```sh
# Build AgentTracker.app and install it into /Applications
make install

open /Applications/AgentTracker.app
```

The app is assembled straight from the SwiftPM build (`make app` if you only
want `dist/AgentTracker.app`), ad-hoc signed by default. Set
`CODESIGN_IDENTITY` to a Developer ID for a distributable build. Installing as
a bundle is what makes the Accessibility grant stick to the app (running via
`swift run` attributes it to your terminal) and enables start-at-login.

For development, `swift run AgentTracker` still works exactly as before.

Ad-hoc signing ties the Accessibility grant to that exact binary, so every
rebuild invalidates it. To make grants survive rebuilds, create a signing
identity once (Keychain Access → Certificate Assistant → Create a Certificate…
→ "AgentTracker Local", type *Code Signing*) and build with
`CODESIGN_IDENTITY="AgentTracker Local" make install`.

Prefer the command line for the agent hookup? `./install.sh` is the same
onboarding as a checkbox picker (non-interactive:
`./install.sh --agents claude --yes`), orchestrating
`./integrations/install-claude-code.sh`.
Everything is idempotent and configs are backed up before editing. To remove it
all again (hooks, the statusline wrapper, the installed app, its preferences),
run `./integrations/uninstall.sh` (add `--purge` to also delete
`~/.agent-tracker`).

Claude's usage windows and context pressure are a separate opt-in, because
capturing them means
occupying the one `statusLine` slot in `~/.claude/settings.json`. The picker
asks, or pass `--statusline` (`--no-statusline` to skip the question). The
wrapper saves the payload and then runs your previous statusline command with
the same bytes on its stdin, so what you see is unchanged; the displaced setting
is recorded under `~/.agent-tracker/` and restored on uninstall. An unrecognized
`statusLine` is left alone rather than replaced.

## Roadmap

- [x] **Notarized builds** (since v0.3.1). Releases are Developer ID
      signed, which keeps your Accessibility grant across updates, and
      notarized, which is why Gatekeeper opens them without asking
- [x] Homebrew tap: `brew install --cask agent-tracker`
- [x] **Notifications** when a session flips to needs-you. Opt-in; click
      jumps to that terminal (Settings › Sessions). See below.
- [x] Onboarding: install as .app + login item
- [x] Downloadable releases, signed so the Accessibility grant survives an update
- [x] **Updates that install themselves**, for direct downloads: daily check
      (on by default), digest and signature verified before the swap,
      automatic install opt-in. Homebrew installs defer to `brew upgrade`

## Support this project

Agent Tracker is free, MIT-licensed, and built in spare time. If it saves you
from hunting through terminal windows, you can say thanks:

- [**GitHub Sponsors**](https://github.com/sponsors/ThinkVelta): one-off or
  monthly, and GitHub takes no cut
- [**PayPal**](https://paypal.me/broekxruben): one-off, no account needed

Starring the repo, reporting a bug you hit, or telling someone who runs three
agents at once helps just as much and costs nothing.

## License

[MIT](LICENSE) · Made by [Ruben Broekx](https://github.com/RubenBroekx)
