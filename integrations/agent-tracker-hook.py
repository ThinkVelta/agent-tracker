#!/usr/bin/env python3
"""Event handler for agent-tracker.

Invoked by agent CLIs on lifecycle events, translates them into per-session
state files under ~/.agent-tracker/sessions/ which the menu bar app watches.

Usage:
  agent-tracker-hook.py claude          # Claude Code hook: reads JSON on stdin
  agent-tracker-hook.py codex <json>    # Codex notify: JSON as final argument

Design constraints: must never block or break the agent session (always exits
0, prints nothing on success) and must be dependency-free (stdlib only).
"""

import json
import os
import subprocess
import sys
import time

SCHEMA_VERSION = 1

# Process names that identify a long-lived agent CLI when walking up the tree.
AGENT_PROCESS_HINTS = ("claude", "codex", "node", "bun")


def sessions_dir():
    base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
    path = os.path.join(base, "sessions")
    os.makedirs(path, exist_ok=True)
    return path


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def agent_pid():
    """Walk up the process tree to find the agent CLI's pid.

    The hook may be spawned via an intermediate shell, so the direct parent is
    not guaranteed to be the agent process. The app uses this pid to prune
    sessions whose agent died without a clean SessionEnd.
    """
    pid = os.getppid()
    fallback = pid
    for _ in range(5):
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout.strip()
            if not out:
                break
            parts = out.split(None, 1)
            if len(parts) < 2:
                break
            comm = os.path.basename(parts[1].strip()).lower()
            if any(hint in comm for hint in AGENT_PROCESS_HINTS):
                return pid
            parent = int(parts[0])
            if parent <= 1:
                break
            pid = parent
        except Exception:  # noqa: BLE001 — the hook must never break a session
            break
    return fallback


def state_path(provider, session_id):
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in session_id)
    return os.path.join(sessions_dir(), f"{provider}-{safe}.json")


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


def update(provider, session_id, event, state, reason, extra):
    path = state_path(provider, session_id)
    current = load_state(path)
    data = {**current}
    data.update({k: v for k, v in extra.items() if v})
    data.update(
        {
            "schema": SCHEMA_VERSION,
            "provider": provider,
            "sessionId": session_id,
            "lastEvent": event,
            "updatedAt": now(),
            "pid": agent_pid(),
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


def handle_claude():
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
    }

    if event == "SessionEnd":
        try:
            os.remove(state_path("claude-code", session_id))
        except FileNotFoundError:
            pass
        return

    tool = payload.get("tool_name")
    # "Stop" is a contract: the app reconsiders a red that came from it (the
    # turn ended, but background work may still be running), and never one from
    # "Notification", which is a permission prompt. Renaming either key here
    # without RegistryEnrichment.turnEndedEvent brings the false reds back.
    mapping = {
        "SessionStart": ("idle", "Session started"),
        "UserPromptSubmit": ("running", "Working…"),
        "PreToolUse": ("running", f"Using {tool}" if tool else "Working…"),
        "PreCompact": ("running", "Compacting context"),
        "Stop": ("needsYou", "Turn complete — ready for you"),
        "Notification": ("needsYou", payload.get("message") or "Needs your attention"),
    }
    state, reason = mapping.get(event, (None, None))
    update("claude-code", session_id, event or "unknown", state, reason, extra)


def handle_codex(args):
    try:
        payload = json.loads(args[0]) if args else {}
    except Exception:  # noqa: BLE001 — malformed input must not break a session
        payload = {}

    def get(*keys):
        for key in keys:
            value = payload.get(key)
            if value:
                return value
        return None

    # thread-id is stable across turns; fall back to the agent pid so repeated
    # notifications from one Codex process collapse into a single session.
    session_id = get("thread-id", "thread_id") or f"pid-{agent_pid()}"
    last_message = get("last-assistant-message", "last_assistant_message")
    if last_message and len(last_message) > 200:
        last_message = last_message[:200] + "…"
    extra = {
        "cwd": get("cwd") or os.getcwd(),
        "termProgram": os.environ.get("TERM_PROGRAM"),
        "lastMessage": last_message,
    }

    event = get("type") or "unknown"
    if event == "agent-turn-complete":
        update(
            "codex",
            session_id,
            event,
            "needsYou",
            "Turn complete — ready for you",
            extra,
        )
    else:
        update("codex", session_id, event, "needsYou", "Needs your attention", extra)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "claude"
    if mode == "claude":
        handle_claude()
    elif mode == "codex":
        handle_codex(sys.argv[2:])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
