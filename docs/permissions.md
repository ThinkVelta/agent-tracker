# Permissions

Three macOS grants, each for one feature. Only the first is needed for the app to
be useful; the other two are for things that are off by default.

| Grant | Needed for | Without it |
| --- | --- | --- |
| **Accessibility** | click-to-focus | rows do not raise their terminal |
| **Automation** (Ghostty) | scheduled continues, app-side rename | those refuse and say why |
| **Notifications** | banners when a session needs you | no banners; everything else works |

## Accessibility

Click-to-focus raises a session's terminal window, switching Spaces if it is on
another one, using the Accessibility API. That API is the only route to raising
another application's specific window, so this grant is what the feature *is*.

Granted during first-run onboarding, or from **System Settings › Privacy &
Security › Accessibility**.

### If it stops working after an update

**Remove the entry with `−` and add it again. Toggling it off and on does not
work.** macOS keys the grant to the binary's signature, so a rebuilt or
re-signed app is a different binary as far as the grant is concerned, and the
stale entry keeps matching the old one.

This bites two groups differently:

- **Released builds** are signed with a stable certificate, so updating keeps the
  grant. If it is ever lost anyway, remove-and-re-add fixes it.
- **Builds you make yourself** are ad-hoc signed unless you pass
  `CODESIGN_IDENTITY`, and those lose the grant on **every rebuild**. That is
  inherent to ad-hoc signing rather than a bug.

## Automation (Ghostty)

Needed only by the two features that write into a terminal: scheduled continues
and renaming from the app. Reading session state never needs it.

**Grant it in advance** from Settings › General › *Permission to control
Ghostty*. This is worth doing before you need it, for a specific reason: the
first request can take a long time. macOS's preflight was measured taking **over
100 seconds** for an app that is running but not yet granted, and that wait lands
in front of whatever you were trying to do.

The prompt is only ever raised at a moment you are present for — arming a
schedule, or renaming. It is never raised while a schedule is firing: a dialog
appearing at 04:00 would sit unanswered and block the very delivery it was meant
to authorise.

### tmux needs none of this

A session running inside `tmux` is addressed entirely differently. The pane
reports its own id and tty, the hook records both when the session starts, and
delivery talks to the tmux server directly — so **no Automation grant is
involved, and nothing is matched by window title**.

That also removes the whole class of "cannot tell which window is yours"
refusals. If you use these features heavily, running sessions in tmux is the
single biggest reliability improvement available.

## Notifications

For the optional banner when a session flips to needing you. **Off by default**:
the menu bar is the passive channel this app was built to be, and a notification
is the most intrusive thing it could do.

Turn it on in Settings › Sessions, which is also when the permission is
requested.

Banners are deliberately **not** marked time-sensitive, which is what lets Focus
and Do Not Disturb hold them. Clicking one jumps to that session's terminal;
acknowledging the session withdraws it.

## What is never asked for

No network permission, because the app makes exactly one kind of outbound
request: the update check against GitHub's releases API, from Settings › About,
when you ask it to. There is no telemetry, no account, and nothing that phones
home on its own.
