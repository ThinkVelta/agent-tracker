#!/bin/bash
# Removes the agent-tracker integrations: surgically strips agent-tracker hook
# entries from ~/.claude/settings.json and the agent-tracker notify line from
# ~/.codex/config.toml, backing each file up first and leaving everything else
# intact. Idempotent. Session data in ~/.agent-tracker is kept unless --purge.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "Usage: uninstall.sh [--purge]"
      echo "  --purge  also remove ~/.agent-tracker (hook script + session data)"
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

SETTINGS="$HOME/.claude/settings.json"
CONFIG="$HOME/.codex/config.toml"
DATA_DIR="$HOME/.agent-tracker"

# --- Claude Code: remove agent-tracker hook entries --------------------------
if [ -f "$SETTINGS" ] && grep -q "agent-tracker-hook" "$SETTINGS"; then
  cp "$SETTINGS" "$SETTINGS.agent-tracker-uninstall-backup"
  echo "Backed up $SETTINGS to $SETTINGS.agent-tracker-uninstall-backup"
  python3 - <<'PYEOF'
import json
import os

settings_path = os.path.expanduser("~/.claude/settings.json")
with open(settings_path) as f:
    settings = json.load(f)

removed = []
hooks = settings.get("hooks", {})
for event in list(hooks):
    entries = hooks[event]
    kept = [
        entry for entry in entries
        if not any(
            "agent-tracker-hook" in h.get("command", "")
            for h in entry.get("hooks", [])
        )
    ]
    if len(kept) == len(entries):
        continue
    removed.append(event)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if removed and not hooks and "hooks" in settings:
    del settings["hooks"]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if removed:
    print(f"Removed agent-tracker hooks for: {', '.join(removed)}")
else:
    print("No agent-tracker hook entries found in settings.json")
PYEOF
else
  echo "Claude Code: no agent-tracker hooks in $SETTINGS — nothing to do"
fi

# --- Codex: remove the agent-tracker notify line -----------------------------
if [ -f "$CONFIG" ] && grep -q "agent-tracker-hook" "$CONFIG"; then
  cp "$CONFIG" "$CONFIG.agent-tracker-uninstall-backup"
  echo "Backed up $CONFIG to $CONFIG.agent-tracker-uninstall-backup"
  python3 - <<'PYEOF'
import os

config_path = os.path.expanduser("~/.codex/config.toml")
with open(config_path) as f:
    lines = f.readlines()

kept = [
    line for line in lines
    if not (line.lstrip().startswith("notify") and "agent-tracker-hook" in line)
]

with open(config_path, "w") as f:
    f.writelines(kept)

count = len(lines) - len(kept)
if count:
    print(f"Removed the agent-tracker notify line from {config_path}")
else:
    print("No agent-tracker notify line found in config.toml")
PYEOF
else
  echo "Codex: no agent-tracker notify line in $CONFIG — nothing to do"
fi

# --- Data directory ----------------------------------------------------------
if [ "$PURGE" -eq 1 ]; then
  if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    echo "Purged $DATA_DIR (hook script + session data removed)"
  else
    echo "Purge: $DATA_DIR does not exist — nothing to do"
  fi
else
  echo "Kept $DATA_DIR (hook script + session data) — pass --purge to remove it"
fi

echo "Done. Restart any running agent sessions to stop them reporting state."
