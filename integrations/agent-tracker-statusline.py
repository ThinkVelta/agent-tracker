#!/usr/bin/env python3
"""Statusline wrapper for agent-tracker.

Claude Code renders one status line per session and hands the script its whole
session payload on stdin, including `rate_limits` — how much of the 5-hour and
7-day windows is used, and the epoch second each resets at. That is the only
place Claude offers those numbers *before* a request is refused, and the app
needs them before the wall to say anything useful about when work can resume.

`settings.json` holds exactly one `statusLine` object, with no array and no
chaining, so capturing the payload means occupying that slot. This script tees:
it saves the payload where the app can read it, then becomes whatever statusline
was configured before, with the same bytes on stdin. Users who had their own
statusline keep seeing it, unchanged.

Usage (registered by install-claude-code.sh --statusline, not run by hand):
  agent-tracker-statusline.py     # reads the JSON payload on stdin

Design constraints, matching agent-tracker-hook.py: stdlib only, and it must
never break a session — every failure path ends in a silent exit 0, because a
blank status line is a cosmetic loss and a traceback on Claude's status line is
not.
"""

import json
import os
import sys
import tempfile

# The payload Claude Code passed us, verbatim.
CAPTURE_NAME = "claude-statusline.json"
# The `statusLine` object this wrapper displaced, so uninstall can put it back
# and so we know what to exec. Kept here rather than in ~/.claude/settings.json:
# our own state is ours to restore from, and writing a private key into
# someone else's config file is how config files end up unparseable.
WRAPPED_NAME = "claude-statusline-wrapped.json"


def base_dir():
    return os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")


def capture(payload):
    """Save the payload for the app, atomically.

    Every live session rewrites this file every few hundred milliseconds and the
    app reads it on its own schedule, so a reader must never see a half-written
    payload. The temporary name carries the pid because the writers are
    concurrent processes sharing one destination — a fixed `.tmp` would let two
    sessions interleave their bytes into the same file before either renamed it.

    Every step is inside the guard, `os.makedirs` included: an unwritable or
    occupied `~/.agent-tracker` would otherwise raise past the caller and cost
    the user their statusline, which is the one thing this script must never do.
    """
    tmp = None
    try:
        directory = base_dir()
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, CAPTURE_NAME)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "wb") as f:
            f.write(payload)
        os.replace(tmp, path)
    except OSError:
        if tmp is None:
            return
        try:
            os.unlink(tmp)
        except OSError:
            pass


def wrapped_command():
    """The statusline command agent-tracker displaced, or None if there was none."""
    path = os.path.join(base_dir(), WRAPPED_NAME)
    try:
        with open(path) as f:
            record = json.load(f)
    except Exception:  # noqa: BLE001 — a corrupt record must not break a session
        return None
    wrapped = record.get("wrapped") if isinstance(record, dict) else None
    command = wrapped.get("command") if isinstance(wrapped, dict) else None
    if isinstance(command, str) and command.strip():
        return command
    return None


def become(command, payload):
    """Hand the payload to the previous statusline and become it.

    `execv` rather than a subprocess so the command inherits this process's
    stdout and owns its exit status directly: what it prints is what Claude Code
    renders, byte for byte, with nothing of ours in the middle and no second
    process to keep alive. stdin is already consumed, so the payload goes back
    onto fd 0 through an unlinked temporary file — the exec keeps the descriptor
    and the file has no name to clean up.

    The exec is outside the guard on purpose. If there is nowhere to stage the
    payload the previous statusline still runs, it just reads an empty stdin —
    a degraded line beats a vanished one, and a machine with no writable temp
    directory has larger problems than this.

    Returns only if the exec failed, in which case the caller exits quietly.
    """
    try:
        # Not a context manager: the descriptor has to outlive this block and
        # survive into the exec, which closing it would defeat. The file is
        # already unlinked, so there is nothing to clean up either way.
        staged = tempfile.TemporaryFile()  # noqa: SIM115
        staged.write(payload)
        staged.seek(0)
        os.dup2(staged.fileno(), 0)
    except OSError:
        pass
    os.execv("/bin/sh", ["/bin/sh", "-c", command])


def main():
    payload = sys.stdin.buffer.read()
    # The invariant, stated where the ordering lives: whatever capturing does,
    # the statusline this wrapper displaced still gets to run. Swallowed rather
    # than logged because anything this script writes lands on Claude's status
    # line, so silence is the only safe report.
    try:
        capture(payload)
    except Exception:  # noqa: BLE001, S110 — never at the cost of the statusline
        pass
    command = wrapped_command()
    if command:
        become(command, payload)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
