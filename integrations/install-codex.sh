#!/bin/bash
# Installs the agent-tracker notify handler into Codex (~/.codex/config.toml).
# Backs up config.toml before touching it. Idempotent; refuses to clobber an
# existing unrelated notify setting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.agent-tracker/bin"
CONFIG="$HOME/.codex/config.toml"

mkdir -p "$BIN_DIR" "$HOME/.agent-tracker/sessions"
cp "$SCRIPT_DIR/agent-tracker-hook.py" "$BIN_DIR/agent-tracker-hook.py"
chmod +x "$BIN_DIR/agent-tracker-hook.py"

if [ -f "$CONFIG" ] && grep -q "agent-tracker-hook" "$CONFIG"; then
  echo "agent-tracker notify handler already registered — nothing to do"
  exit 0
fi

if [ -f "$CONFIG" ] && grep -Eq '^[[:space:]]*notify[[:space:]]*=' "$CONFIG"; then
  echo "ERROR: $CONFIG already sets 'notify' to something else." >&2
  echo "Merge manually: notify = [\"python3\", \"$BIN_DIR/agent-tracker-hook.py\", \"codex\"]" >&2
  exit 1
fi

if [ -f "$CONFIG" ]; then
  cp "$CONFIG" "$CONFIG.agent-tracker-backup"
  echo "Backed up $CONFIG to $CONFIG.agent-tracker-backup"
fi

# 'notify' is a top-level TOML key, so it must be inserted before the first
# [section] header — prepending is the only always-safe placement.
python3 - << PYEOF
import os

config_path = os.path.expanduser("~/.codex/config.toml")
line = 'notify = ["python3", "$BIN_DIR/agent-tracker-hook.py", "codex"]\n'

existing = ""
if os.path.exists(config_path):
    with open(config_path) as f:
        existing = f.read()

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    f.write(line + existing)

print("Registered agent-tracker notify handler")
PYEOF

echo "Done. New Codex sessions will now push turn-complete notifications."
echo "Note: the app also tracks Codex live by watching ~/.codex/sessions"
echo "(read-only), so running/needs-you states work even without this notify."
