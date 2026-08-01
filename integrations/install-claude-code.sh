#!/bin/bash
# Installs the agent-tracker hook into Claude Code (~/.claude/settings.json).
# Copies the hook script to ~/.agent-tracker/bin/ so sessions keep working even
# if this repo moves. Backs up settings.json before touching it. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.agent-tracker/bin"
SETTINGS="$HOME/.claude/settings.json"

# ~/.claude may not exist yet (claude installed but never run) — the merge
# below writes settings.json into it.
mkdir -p "$BIN_DIR" "$HOME/.agent-tracker/sessions" "$HOME/.claude"
cp "$SCRIPT_DIR/agent-tracker-hook.py" "$BIN_DIR/agent-tracker-hook.py"
chmod +x "$BIN_DIR/agent-tracker-hook.py"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.agent-tracker-backup"
  echo "Backed up $SETTINGS to $SETTINGS.agent-tracker-backup"
fi

python3 - <<'PYEOF'
import json
import os

settings_path = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

command = os.path.expanduser("~/.agent-tracker/bin/agent-tracker-hook.py") + " claude"
hook_entry = {"type": "command", "command": command, "timeout": 10}

EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PreCompact",
    "Stop",
    "Notification",
    "SessionEnd",
]
TOOL_EVENTS = {"PreToolUse"}

hooks = settings.setdefault("hooks", {})
added = []
for event in EVENTS:
    entries = hooks.setdefault(event, [])
    already = any(
        "agent-tracker-hook" in h.get("command", "")
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if already:
        continue
    entry = {"hooks": [hook_entry]}
    if event in TOOL_EVENTS:
        entry["matcher"] = "*"
    entries.append(entry)
    added.append(event)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if added:
    print(f"Registered agent-tracker hooks for: {', '.join(added)}")
else:
    print("agent-tracker hooks already registered — nothing to do")
PYEOF

echo "Done. New Claude Code sessions will now report their state."
echo "Note: already-running sessions pick up hooks on their next restart."
