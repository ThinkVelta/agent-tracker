#!/usr/bin/env python3
"""Event handler for agent-tracker.

Invoked by agent CLIs on lifecycle events, translates them into per-session
state files under ~/.agent-tracker/sessions/ which the menu bar app watches.

Usage:
  agent-tracker-hook.py claude          # Claude Code hook: reads JSON on stdin
  agent-tracker-hook.py codex-hook      # Codex native hook: reads JSON on stdin
  agent-tracker-hook.py codex <json>    # Codex legacy notify: JSON as final argument

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
# Load-bearing rather than tidiness: Codex runs its hooks synchronously
# (`async: true` is parsed but skipped — "async hooks are not supported yet"),
# and one of the events we register for is `PermissionRequest`, which sits in
# the approval path. A hook that overruns its configured timeout there is not a
# missed state update, it is an approval prompt we interfered with. The happy
# path takes ~40ms; this only bites when `ps` itself is wedged.
PROCESS_WALK_BUDGET = 2.0

# Process names that identify a long-lived agent CLI when walking up the tree.
AGENT_PROCESS_HINTS = ("claude", "codex", "node", "bun")

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
    pid, tty = agent_process()
    data = {**current}
    data.update({k: v for k, v in extra.items() if v})
    identity = terminal_identity(tty)
    if identity:
        data["terminal"] = identity
    data.update(
        {
            "schema": SCHEMA_VERSION,
            "provider": provider,
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
    ended, but background work may still be running), and never one from
    "Notification", which is a permission prompt. Renaming either key here
    without RegistryEnrichment.turnEndedEvent brings the false reds back.
    """
    tool = payload.get("tool_name")
    return {
        "SessionStart": ("idle", "Session started"),
        "UserPromptSubmit": ("running", "Working…"),
        "PreToolUse": ("running", f"Using {tool}" if tool else "Working…"),
        "PreCompact": ("running", "Compacting context"),
        "Stop": ("needsYou", "Turn complete — ready for you"),
        "Notification": ("needsYou", payload.get("message") or "Needs your attention"),
    }


def codex_states(payload):
    """Codex's native hook events, as states.

    Deliberately parallel to `claude_states`: Codex's hooks carry the same
    stdin payload shape, and "PermissionRequest" plays the part "Notification"
    plays for Claude — the one event that means a prompt is waiting rather than
    a turn having finished. That distinction is the whole reason to prefer
    these hooks over the legacy `notify`, which cannot see it.

    No subagent guard here, and that is measured rather than assumed: across
    1213 rollouts on a real multi-agent machine, every one of the 1171 subagent
    threads carried the *root* session's `session_id` — only the thread id
    differs, with `parent_thread_id` pointing up the tree — and all 19 sessions
    that had subagents shared one `session_id` with their root. So a hook fired
    inside a subagent writes to the root session's file, which is what we want:
    its `PreToolUse` reads as the session working, and its `PermissionRequest`
    turns the session red, because the user really does have to approve it.
    This is what the legacy `notify` gets wrong — it reports a thread id, which
    is why `CodexSubagentLedger` and `threadIdToSession` exist.
    """
    tool = payload.get("tool_name")
    return {
        "SessionStart": ("idle", "Session started"),
        "UserPromptSubmit": ("running", "Working…"),
        "PreToolUse": ("running", f"Using {tool}" if tool else "Working…"),
        "PreCompact": ("running", "Compacting context"),
        "Stop": ("needsYou", "Turn complete — ready for you"),
        "PermissionRequest": (
            "needsYou",
            f"Approve {tool}?" if tool else "Waiting on your approval",
        ),
    }


def handle_hook(provider, states):
    """Handle one stdin-delivered hook payload.

    Shared by Claude Code and Codex, which agree on the wire format down to the
    field names (`hook_event_name`, `session_id`, `cwd`, `transcript_path`).
    Only the event vocabulary differs, which is what `states` supplies.
    """
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
        # Which mechanism wrote this. For Codex the app has a second, weaker
        # view of the same session (rollout files), and it needs to know which
        # rows came from something that watched the whole lifecycle.
        "origin": "hook",
    }

    if event == "SessionEnd":
        try:
            os.remove(state_path(provider, session_id))
        except FileNotFoundError:
            pass
        return

    state, reason = states(payload).get(event, (None, None))
    update(provider, session_id, event or "unknown", state, reason, extra)


def handle_codex(args):
    """Codex's legacy `notify` callback: one event, fired after a turn ends.

    Superseded by `codex-hook` above, which sees the whole lifecycle. Kept
    because a session that was already running when the hooks were installed
    still reports through this, and because `notify` remains in config.toml
    until the user uninstalls it.
    """
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
    session_id = get("thread-id", "thread_id") or f"pid-{agent_process()[0]}"
    last_message = get("last-assistant-message", "last_assistant_message")
    if last_message and len(last_message) > 200:
        last_message = last_message[:200] + "…"
    extra = {
        "cwd": get("cwd") or os.getcwd(),
        "termProgram": os.environ.get("TERM_PROGRAM"),
        "lastMessage": last_message,
        "origin": "notify",
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
        handle_hook("claude-code", claude_states)
    elif mode == "codex-hook":
        handle_hook("codex", codex_states)
    elif mode == "codex":
        handle_codex(sys.argv[2:])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
