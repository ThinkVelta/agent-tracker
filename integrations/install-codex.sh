#!/bin/bash
# Installs the agent-tracker integration into Codex.
#
# Two registrations, because Codex has two mechanisms and they see different
# things:
#
#   ~/.codex/hooks.json   native lifecycle hooks — the whole session, including
#                         PermissionRequest, which is the only way to know an
#                         approval prompt is open rather than a turn having ended
#   ~/.codex/config.toml  the legacy `notify` callback — fires once, after a
#                         turn completes
#
# `notify` is kept alongside because a session that was already running when
# this ran keeps reporting through it, and because the two agree on the session
# id Codex writes into its rollout files, so they never produce two rows.
#
# Both edits are idempotent, back the file up first, and refuse to clobber an
# unrelated setting rather than overwrite it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${AGENT_TRACKER_DIR:-$HOME/.agent-tracker}"
BIN_DIR="$BASE_DIR/bin"
HOOKS="$HOME/.codex/hooks.json"
CONFIG="$HOME/.codex/config.toml"

mkdir -p "$BIN_DIR" "$BASE_DIR/sessions" "$HOME/.codex"
cp "$SCRIPT_DIR/agent-tracker-hook.py" "$BIN_DIR/agent-tracker-hook.py"
chmod +x "$BIN_DIR/agent-tracker-hook.py"

# --- Native hooks (~/.codex/hooks.json) --------------------------------------
HOOKS_STATUS=0
AGENT_TRACKER_HOOKS_PATH="$HOOKS" python3 - << 'PYEOF' || HOOKS_STATUS=$?
import json
import os
import shlex
import shutil
import sys

hooks_path = os.environ["AGENT_TRACKER_HOOKS_PATH"]
base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
hook = os.path.join(base, "bin", "agent-tracker-hook.py")
command = f"{shlex.quote(hook)} codex-hook"

# Codex clamps a SessionEnd hook to 3s and prints a warning if asked for more,
# so ask for exactly what it allows rather than making every session start with
# a complaint about our config.
SESSION_END_TIMEOUT = 3
DEFAULT_TIMEOUT = 10

# Every event carries "matcher": "*". Claude's installer sets a matcher only on
# tool events, but Codex's own generated config sets one everywhere, and that is
# the shape proven to load — whether Codex treats it as optional is not worth
# discovering on a user's machine.
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PreCompact",
    "PermissionRequest",
    "Stop",
    "SessionEnd",
]

document = {}
if os.path.exists(hooks_path):
    try:
        with open(hooks_path) as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"Cannot read {hooks_path} as JSON: {error}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(document, dict):
        print(f"{hooks_path} is not a JSON object — refusing to rewrite it.", file=sys.stderr)
        sys.exit(2)

hooks = document.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print(f'{hooks_path} has a "hooks" key that is not an object.', file=sys.stderr)
    sys.exit(2)

added = []
for event in EVENTS:
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print(f'{hooks_path}: "hooks.{event}" is not a list.', file=sys.stderr)
        sys.exit(2)
    already = any(
        "agent-tracker-hook" in entry.get("command", "")
        for group in groups
        if isinstance(group, dict)
        for entry in group.get("hooks", [])
        if isinstance(entry, dict)
    )
    if already:
        continue
    timeout = SESSION_END_TIMEOUT if event == "SessionEnd" else DEFAULT_TIMEOUT
    # Appended, never inserted: Codex keys hook trust by position
    # (`<path>:<event>:<group>:<index>`), so putting ours first would invalidate
    # the trust the user already granted every hook it displaced.
    groups.append(
        {
            "matcher": "*",
            "hooks": [{"type": "command", "command": command, "timeout": timeout}],
        }
    )
    added.append(event)

if not added:
    print("agent-tracker hooks already registered — nothing to do")
    sys.exit(0)

# Backed up here rather than before the merge, so re-running does not replace a
# pristine backup with a copy of the file we already edited.
if os.path.exists(hooks_path):
    shutil.copyfile(hooks_path, hooks_path + ".agent-tracker-backup")
    print(f"Backed up {hooks_path} to {hooks_path}.agent-tracker-backup")

with open(hooks_path, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")

print(f"Registered agent-tracker hooks for: {', '.join(added)}")
PYEOF

if [ "$HOOKS_STATUS" -eq 2 ]; then
  echo "ERROR: $HOOKS is not in a shape this installer can merge into." >&2
  echo "Add this command by hand under each lifecycle event instead:" >&2
  echo "  $BIN_DIR/agent-tracker-hook.py codex-hook" >&2
  exit 1
elif [ "$HOOKS_STATUS" -ne 0 ]; then
  exit "$HOOKS_STATUS"
fi

# --- Legacy notify (~/.codex/config.toml) ------------------------------------
# The python block decides among: already ours (exit 0, no change), unrelated
# notify present (exit 2, no change), or absent (backup + prepend — 'notify'
# is a top-level TOML key, so it must precede the first [section] header).
STATUS=0
python3 - "$BIN_DIR" "$CONFIG" << 'PYEOF' || STATUS=$?
import os
import re
import shutil
import sys

bin_dir = sys.argv[1]
config_path = sys.argv[2]
notify_line = f'notify = ["python3", "{bin_dir}/agent-tracker-hook.py", "codex"]\n'

lines = []
if os.path.exists(config_path):
    with open(config_path) as f:
        lines = f.readlines()

# Scan only the top-level key area: keys after the first [section] header
# belong to that table, and comments never match the key regex.
state = "absent"
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r"[ \t]*\[", line):
        break
    if re.match(r"[ \t]*notify[ \t]*=", line):
        block = [line]
        depth = line.count("[") - line.count("]")
        j = i + 1
        while depth > 0 and j < len(lines):
            block.append(lines[j])
            depth += lines[j].count("[") - lines[j].count("]")
            j += 1
        state = "ours" if any("agent-tracker-hook" in b for b in block) else "other"
        break
    i += 1

if state == "ours":
    print("agent-tracker notify handler already registered — nothing to do")
    sys.exit(0)
if state == "other":
    sys.exit(2)

if os.path.exists(config_path):
    shutil.copyfile(config_path, config_path + ".agent-tracker-backup")
    print(f"Backed up {config_path} to {config_path}.agent-tracker-backup")

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    f.writelines([notify_line] + lines)

print("Registered agent-tracker notify handler")
PYEOF

if [ "$STATUS" -eq 2 ]; then
  echo "NOTE: $CONFIG already sets 'notify' to something else, so it was left alone." >&2
  echo "The native hooks above cover everything notify would have, so this is fine." >&2
  echo "To have both: notify = [\"python3\", \"$BIN_DIR/agent-tracker-hook.py\", \"codex\"]" >&2
elif [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

# On stderr, because it is the one thing left for the user to do: onboarding
# prefixes stdout with a tick and stderr with a warning marker, and a tick
# against "you still have to accept a prompt" reads as though they did not.
echo "ONE STEP LEFT: Codex runs a hook only once you have trusted it. Your next" >&2
echo "Codex launch shows a hook review prompt naming agent-tracker; accept it, or" >&2
echo "none of the above runs. 'codex exec' skips untrusted hooks silently, so" >&2
echo "nothing else will tell you it is waiting." >&2
echo "Already-running sessions pick the hooks up on their next restart." >&2
