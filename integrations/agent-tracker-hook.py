#!/usr/bin/env python3
"""Event handler for agent-tracker.

Invoked by Claude Code on lifecycle events, translates them into per-session
state files under ~/.agent-tracker/sessions/ which the menu bar app watches.

Usage:
  agent-tracker-hook.py claude          # reads the hook payload as JSON on stdin

Design constraints: must never block or break the agent session (always exits
0, prints nothing on success) and must be dependency-free (stdlib only).
"""

import functools
import json
import os
import subprocess
import sys
import time

SCHEMA_VERSION = 1


# Wall-clock budget for the whole process-tree walk, across every `ps` it runs.
#
# Load-bearing rather than tidiness: hooks run in the session's own path, so one
# that overruns is not a missed state update — it is an agent left waiting on
# us. The happy path takes ~40ms; this only bites when `ps` itself is wedged.
PROCESS_WALK_BUDGET = 2.0

# Process names that identify a long-lived agent CLI when walking up the tree.
AGENT_PROCESS_HINTS = ("claude", "node", "bun")

# Which terminal pane the session occupies, as the environment reports it.
# Captured here because it is free at hook time and unrecoverable afterwards:
# the app cannot ask a terminal "which pane holds pid N" unless the terminal
# exposes that, and several of these ARE the pane handle. TERM_PROGRAM has
# always worked, which is the proof that the hook inherits the session's
# environment.
TERMINAL_ENV_KEYS = {
    "term": "TERM",
    "tmux": "TMUX",
    "tmuxPane": "TMUX_PANE",
    "weztermPane": "WEZTERM_PANE",
    "kittyWindowId": "KITTY_WINDOW_ID",
    "kittyListenOn": "KITTY_LISTEN_ON",
    "itermSessionId": "ITERM_SESSION_ID",
    "termSessionId": "TERM_SESSION_ID",
    "alacrittyWindowId": "ALACRITTY_WINDOW_ID",
}


def sessions_dir():
    base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
    path = os.path.join(base, "sessions")
    os.makedirs(path, exist_ok=True)
    return path


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


@functools.lru_cache(maxsize=1)
def agent_process():
    """Walk up the process tree to find the agent CLI's pid and its tty.

    The hook may be spawned via an intermediate shell, so the direct parent is
    not guaranteed to be the agent process. The app uses this pid to prune
    sessions whose agent died without a clean SessionEnd.

    The tty comes from the same `ps` call rather than this process: the hook is
    handed its payload on stdin, so its own fd 0 is a pipe and names no
    terminal. The agent's tty is what identifies the pane it runs in.

    Cached because one hook invocation resolves one process, and the callers
    would otherwise repeat the whole walk.
    """
    pid = os.getppid()
    fallback = (pid, None)
    deadline = time.monotonic() + PROCESS_WALK_BUDGET
    for _ in range(5):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
                capture_output=True,
                text=True,
                timeout=remaining,
                check=False,
            ).stdout.strip()
            if not out:
                break
            parts = out.split(None, 2)
            if len(parts) < 3:
                break
            comm = os.path.basename(parts[2].strip()).lower()
            if any(hint in comm for hint in AGENT_PROCESS_HINTS):
                return pid, device_path(parts[1])
            parent = int(parts[0])
            if parent <= 1:
                break
            pid = parent
        except Exception:  # noqa: BLE001 — the hook must never break a session
            break
    return fallback


def device_path(tty):
    """`ps` prints a bare `ttys003`, or `??` for a process with no terminal."""
    name = (tty or "").strip()
    if not name or name in ("??", "-"):
        return None
    return name if name.startswith("/") else "/dev/" + name


def terminal_identity(tty):
    """The pane handles this session can be recognized by, omitting the absent."""
    identity = {key: os.environ.get(var) for key, var in TERMINAL_ENV_KEYS.items()}
    identity["tty"] = tty
    return {key: value for key, value in identity.items() if value}


# The filename keeps its provider prefix, and the payload keeps its `provider`
# field, from when this served more than one agent. Both are deliberate: an
# upgrade must not orphan the state file of a session that is still running, and
# an app build from before this change still reads what this writes.
STATE_FILE_PREFIX = "claude-code"


def state_path(session_id):
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in session_id)
    return os.path.join(sessions_dir(), f"{STATE_FILE_PREFIX}-{safe}.json")


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:  # noqa: BLE001 — corrupt state must not break a session
        return {}


def write_state(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def update(session_id, event, state, reason, extra):
    path = state_path(session_id)
    current = load_state(path)
    pid, tty = agent_process()
    data = {**current}
    data.update({k: v for k, v in extra.items() if v})
    identity = terminal_identity(tty)
    if identity:
        data["terminal"] = identity
    data.update(
        {
            "schema": SCHEMA_VERSION,
            "provider": STATE_FILE_PREFIX,
            "sessionId": session_id,
            "lastEvent": event,
            "updatedAt": now(),
            "pid": pid,
        }
    )
    if state is not None:
        if current.get("state") != state:
            data["stateChangedAt"] = now()
        data["state"] = state
        data["reason"] = reason
    data.setdefault("state", "idle")
    data.setdefault("stateChangedAt", now())
    write_state(path, data)


def claude_states(payload):
    """Claude Code's lifecycle events, as states.

    "Stop" is a contract: the app reconsiders a red that came from it (the turn
    ended, but background work may still be running). A "Notification" red is
    reconsidered only when its notification_type says "idle_prompt", which
    Claude sends after a turn has sat still for a while, background shell or
    not; a permission prompt is never reconsidered. Renaming either key here,
    or dropping notificationType below, brings the false reds back.
    """
    tool = payload.get("tool_name")
    return {
        "SessionStart": ("idle", "Session started"),
        "UserPromptSubmit": ("running", "Working…"),
        "PreToolUse": ("running", f"Using {tool}" if tool else "Working…"),
        "PreCompact": ("running", "Compacting context"),
        "Stop": ("needsYou", "Turn complete, ready for you"),
        "Notification": ("needsYou", payload.get("message") or "Needs your attention"),
    }


def handle_hook():
    """Handle one stdin-delivered hook payload."""
    try:
        payload = json.load(sys.stdin)
    except Exception:  # noqa: BLE001 — malformed input must not break a session
        return
    event = payload.get("hook_event_name", "")
    session_id = payload.get("session_id") or "unknown"
    extra = {
        "cwd": payload.get("cwd"),
        "transcriptPath": payload.get("transcript_path"),
        "termProgram": os.environ.get("TERM_PROGRAM"),
        # Whether this session acts without asking. The scheduled-continue gate
        # reads it, and treats "absent" as permitted, so it is worth recording
        # even though the transcript carries it too.
        "permissionMode": payload.get("permission_mode"),
        # Which kind of Notification this was. The app promotes an idle-prompt
        # red back to running when Claude's own status says work continues,
        # and must never do that for a permission prompt; only this field
        # tells the two apart, so its absence reads as the safe kind.
        "notificationType": payload.get("notification_type"),
    }

    if event == "SessionEnd":
        try:
            os.remove(state_path(session_id))
        except FileNotFoundError:
            pass
        return

    state, reason = claude_states(payload).get(event, (None, None))
    update(session_id, event or "unknown", state, reason, extra)


def main():
    # Any other mode is a no-op that still exits 0. An install from before this
    # app was Claude-only may still have a registration for another agent
    # pointing here, and a hook that errors is a hook that interrupts somebody's
    # session — the uninstaller removes those, this makes them harmless first.
    if (sys.argv[1] if len(sys.argv) > 1 else "claude") == "claude":
        handle_hook()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
