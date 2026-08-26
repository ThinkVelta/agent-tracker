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


# Wall-clock budget for the one `ps` the process-tree walk runs.
#
# Load-bearing rather than tidiness: hooks run in the session's own path, so one
# that overruns is not a missed state update — it is an agent left waiting on
# us. The happy path takes ~40ms; this only bites when `ps` itself is wedged.
PROCESS_WALK_BUDGET = 2.0

# How far up the tree to look. Login → shell → wrapper → agent needs four; an
# agent's own Bash tool → script → nested agent needs a few more above that.
PROCESS_WALK_DEPTH = 12

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


def process_table():
    """Every process as {pid: (ppid, tty, comm)}, from one `ps`; {} on failure."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,tty=,comm="],
            capture_output=True,
            text=True,
            timeout=PROCESS_WALK_BUDGET,
            check=False,
        ).stdout
    except Exception:  # noqa: BLE001 — the hook must never break a session
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            table[int(parts[0])] = (int(parts[1]), parts[2], parts[3].strip())
        except ValueError:
            continue
    return table


def is_agent(comm):
    name = os.path.basename(comm).lower()
    return any(hint in name for hint in AGENT_PROCESS_HINTS)


def agent_lineage(table, start):
    """(agent pid, its tty, the enclosing agent's pid) walking up from `start`.

    The first agent process above the hook is the session's own. An agent
    above THAT is the one whose tool started this session: a `claude -p` run
    by a script from a session's Bash tool has its own session id and fires
    the same hooks, but it is that session's work, not a session of its own.
    Pure so the walk is testable without a process tree.
    """
    pid = start
    agent = None
    tty = None
    for _ in range(PROCESS_WALK_DEPTH):
        entry = table.get(pid)
        if entry is None:
            break
        ppid, raw_tty, comm = entry
        if is_agent(comm):
            if agent is None:
                agent, tty = pid, raw_tty
            else:
                return agent, tty, pid
        if ppid <= 1:
            break
        pid = ppid
    return agent, tty, None


@functools.lru_cache(maxsize=1)
def agent_process():
    """The agent CLI's pid and tty, plus the pid of an agent it runs under.

    The hook may be spawned via an intermediate shell, so the direct parent is
    not guaranteed to be the agent process. The app uses this pid to prune
    sessions whose agent died without a clean SessionEnd.

    The tty comes from `ps` rather than this process: the hook is handed its
    payload on stdin, so its own fd 0 is a pipe and names no terminal. The
    agent's tty is what identifies the pane it runs in.

    Cached because one hook invocation resolves one process, and the callers
    would otherwise repeat the whole walk.
    """
    start = os.getppid()
    agent, tty, spawned_by = agent_lineage(process_table(), start)
    if agent is None:
        return start, None, None
    return agent, device_path(tty), spawned_by


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


def update(session_id, event, state, reason, extra, background_tasks=None):
    path = state_path(session_id)
    current = load_state(path)
    pid, tty, spawned_by = agent_process()
    data = {**current}
    # Written from this event alone, like notificationType below: a value that
    # outlived the process it named could hide a session once the pid is reused.
    if spawned_by:
        data["spawnedByPid"] = spawned_by
    else:
        data.pop("spawnedByPid", None)
    data.update({k: v for k, v in extra.items() if v})
    if background_tasks is not None:
        data["backgroundTasks"] = merge_background_tasks(
            background_tasks, current.get("backgroundTasks")
        )
    # notificationType is event-local, not a stable session fact like cwd or
    # the terminal: a Notification's type must describe THIS event only. The
    # truthy merge above would let an old idle_prompt survive into a later
    # permission prompt and falsely mark it promotable, so set it from this
    # event alone and clear it when this event does not carry one.
    if extra.get("notificationType"):
        data["notificationType"] = extra["notificationType"]
    else:
        data.pop("notificationType", None)
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


# How much of a background command the state file keeps. Enough for the app
# to recognise the shell process it belongs to and to show what it was doing;
# a multi-page script would otherwise be copied into the file on every turn.
COMMAND_EXCERPT = 300

# Task types that keep Claude's status at "shell" after a turn ends. Subagents,
# workflows and teammates report "busy" instead and are not recorded.
SHELL_TASK_TYPES = ("shell", "monitor")


def in_flight_shells(payload):
    """The background shells a Stop payload says are still running, or None.

    Claude Code (2.1.145+) lists in-flight background work on `Stop` so hooks
    can tell "the session is done" from "the session is parked on a shell".
    None when the payload has no such field, which is how an older Claude
    must read: unknown, not empty.
    """
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        return None
    shells = []
    for task in tasks:
        if not isinstance(task, dict) or task.get("type") not in SHELL_TASK_TYPES:
            continue
        task_id = task.get("id")
        if not isinstance(task_id, str) or not task_id:
            continue
        shell = {"id": task_id, "type": task["type"]}
        for key in ("description", "command"):
            value = task.get(key)
            if isinstance(value, str) and value:
                shell[key] = value[:COMMAND_EXCERPT]
        # Says whether the excerpt is the whole command: a whole one must match
        # its shell exactly, or "sleep 27" would also claim "sleep 2700".
        if len(task.get("command") or "") > COMMAND_EXCERPT:
            shell["commandTruncated"] = True
        shells.append(shell)
    return shells


def merge_background_tasks(shells, previous):
    """Carry each shell's first sighting forward across turns.

    The payload says what is running now, never since when, so the age of a
    shell is the age of its first appearance in a Stop. A shell that has left
    the list is gone with its timestamp.
    """
    seen_at = {}
    for task in previous or []:
        if isinstance(task, dict) and task.get("id") and task.get("firstSeenAt"):
            seen_at[task["id"]] = task["firstSeenAt"]
    stamp = now()
    return [
        {**shell, "firstSeenAt": seen_at.get(shell["id"], stamp)} for shell in shells
    ]


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
    shells = in_flight_shells(payload) if event == "Stop" else None
    update(
        session_id, event or "unknown", state, reason, extra, background_tasks=shells
    )


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
