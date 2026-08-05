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
    """
    directory = base_dir()
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, CAPTURE_NAME)
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(payload)
        os.replace(tmp, path)
    except OSError:
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

    Returns only if the exec failed, in which case the caller exits quietly.
    """
    with tempfile.TemporaryFile() as stdin:
        stdin.write(payload)
        stdin.seek(0)
        os.dup2(stdin.fileno(), 0)
        os.execv("/bin/sh", ["/bin/sh", "-c", command])


def main():
    payload = sys.stdin.buffer.read()
    capture(payload)
    command = wrapped_command()
    if command:
        become(command, payload)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
