#!/usr/bin/env python3
"""agent-tracker's built-in statusline for Claude Code.

Renders the session payload Claude hands its status line into two lines:

  Model | effort: high | ctx: 8% | 5h: 67% (->15:40) | 7d: 13% (->Wed 17:00) | <session id>
  +12 -3 | branch * | .../parent/dir

The wrapper (agent-tracker-statusline.py) execs this when the user picked
"agent-tracker's statusline" — recorded as `"display": "builtin"` in
~/.agent-tracker/claude-statusline-wrapped.json — so this never occupies the
statusLine slot itself and never captures anything; the wrapper already did.

Design constraints, matching the other integrations: stdlib only, compatible
with the macOS system python3, and it must never break a session — every
failure path degrades to printing less, and the process always exits 0,
because a blank status line is a cosmetic loss and a traceback on Claude's
status line is not. Git is the one subprocess and the one thing that can
stall, so every call carries a timeout and any failure simply drops the
branch segment.
"""

import json
import subprocess
import sys
import time

RESET = "\033[0m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"

# Statusline repaints are frequent; a git call that cannot answer promptly
# is dropped rather than awaited, or slow repos would pile up processes.
GIT_TIMEOUT = 2.0


def colorpct(value, warn, crit):
    if value >= crit:
        return RED
    if value >= warn:
        return YELLOW
    return GREEN


def percent(container, *keys):
    """Digs a used_percentage out of nested dicts; None when absent."""
    node = container
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    if isinstance(node, (int, float)) and not isinstance(node, bool):
        return node
    return None


def git(directory, *args):
    """One git call, or None on any failure at all — including a slow one."""
    try:
        done = subprocess.run(
            ["git", "-C", directory, *args],
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    return done.stdout.rstrip("\n")


def branch_segment(directory):
    if git(directory, "rev-parse", "--is-inside-work-tree") != "true":
        return ""
    name = git(directory, "branch", "--show-current")
    if not name:
        name = git(directory, "rev-parse", "--short", "HEAD")
    if not name:
        return ""
    dirty = ""
    porcelain = git(directory, "status", "--porcelain")
    if porcelain:
        dirty = f" {YELLOW}✱{RESET}"
    return f"{CYAN}{name}{RESET}{dirty}"


def short_directory(directory):
    """Up to 3 trailing path components, fewer when the names run long.

    Parents dimmed, the current folder in the default colour, and a dimmed
    `.../` prefix whenever something was cut.
    """
    components = [part for part in directory.split("/") if part]
    if not components:
        return ""
    count = len(components)
    max_length = 40
    depth = 1
    for candidate_depth in (3, 2, 1):
        if candidate_depth > count:
            continue
        candidate = "/".join(components[count - candidate_depth :])
        if candidate_depth < count:
            candidate = ".../" + candidate
        if len(candidate) <= max_length or candidate_depth == 1:
            depth = candidate_depth
            break
    start = count - depth
    prefix = f"{DIM}.../{RESET}" if depth < count else ""
    middle = "".join(f"{DIM}{part}/{RESET}" for part in components[start : count - 1])
    return f"{prefix}{middle}{components[count - 1]}"


def limit_segment(payload, window_key, label, reset_format):
    used = percent(payload, "rate_limits", window_key, "used_percentage")
    if used is None:
        return ""
    value = int(f"{used:.0f}")
    segment = f"{label}: {colorpct(value, 70, 90)}{value}%{RESET}"
    resets_at = percent(payload, "rate_limits", window_key, "resets_at")
    if resets_at and resets_at > 0:
        moment = time.strftime(reset_format, time.localtime(resets_at))
        segment += f" {DIM}(→{moment}){RESET}"
    return segment


def render(payload):
    model = "unknown model"
    if isinstance(payload.get("model"), dict):
        model = payload["model"].get("display_name") or model

    line1 = [model]

    effort = None
    if isinstance(payload.get("effort"), dict):
        effort = payload["effort"].get("level")
    if effort:
        line1.append(f"effort: {YELLOW}{effort}{RESET}")

    context = percent(payload, "context_window", "used_percentage")
    if context is None:
        line1.append("ctx: --")
    else:
        value = int(f"{context:.0f}")
        line1.append(f"ctx: {colorpct(value, 50, 80)}{value}%{RESET}")

    for segment in (
        limit_segment(payload, "five_hour", "5h", "%H:%M"),
        limit_segment(payload, "seven_day", "7d", "%a %H:%M"),
    ):
        if segment:
            line1.append(segment)

    session_id = payload.get("session_id")
    if session_id:
        line1.append(f"{DIM}{session_id}{RESET}")

    line2 = []
    cost = payload.get("cost") if isinstance(payload.get("cost"), dict) else {}
    added = cost.get("total_lines_added")
    removed = cost.get("total_lines_removed")
    if added is not None or removed is not None:
        line2.append(f"{GREEN}+{added or 0}{RESET} {RED}-{removed or 0}{RESET}")

    directory = None
    if isinstance(payload.get("workspace"), dict):
        directory = payload["workspace"].get("current_dir")
    if directory:
        branch = branch_segment(directory)
        if branch:
            line2.append(branch)
        shortdir = short_directory(directory)
        if shortdir:
            line2.append(shortdir)

    output = " | ".join(line1) + "\n"
    if line2:
        output += " | ".join(line2)
    return output


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:  # noqa: BLE001 — malformed input renders nothing, breaks nothing
        return 0
    if not isinstance(payload, dict):
        return 0
    sys.stdout.write(render(payload))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — never break the agent session
        sys.exit(0)
