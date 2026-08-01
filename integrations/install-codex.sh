#!/bin/bash
# Installs the agent-tracker notify handler into Codex (~/.codex/config.toml).
# Detection is TOML-structure-aware (top-level `notify` key only, bracket-
# balanced for multi-line arrays — commented-out lines and section-scoped keys
# don't count). Backs up config.toml before touching it. Idempotent; refuses
# to clobber an existing unrelated notify setting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.agent-tracker/bin"

mkdir -p "$BIN_DIR" "$HOME/.agent-tracker/sessions"
cp "$SCRIPT_DIR/agent-tracker-hook.py" "$BIN_DIR/agent-tracker-hook.py"
chmod +x "$BIN_DIR/agent-tracker-hook.py"

# The python block decides among: already ours (exit 0, no change), unrelated
# notify present (exit 2, no change), or absent (backup + prepend — 'notify'
# is a top-level TOML key, so it must precede the first [section] header).
STATUS=0
python3 - "$BIN_DIR" << 'PYEOF' || STATUS=$?
import os
import re
import shutil
import sys

bin_dir = sys.argv[1]
config_path = os.path.expanduser("~/.codex/config.toml")
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
  CONFIG="$HOME/.codex/config.toml"
  echo "ERROR: $CONFIG already sets 'notify' to something else." >&2
  echo "Merge manually: notify = [\"python3\", \"$BIN_DIR/agent-tracker-hook.py\", \"codex\"]" >&2
  exit 1
elif [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

echo "Done. New Codex sessions will now push turn-complete notifications."
echo "Note: the app also tracks Codex live by watching ~/.codex/sessions"
echo "(read-only), so running/needs-you states work even without this notify."
