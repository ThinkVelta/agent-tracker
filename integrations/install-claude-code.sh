#!/bin/bash
# Installs the agent-tracker hook into Claude Code (~/.claude/settings.json).
# Copies the hook script to ~/.agent-tracker/bin/ so sessions keep working even
# if this repo moves. Backs up settings.json before touching it. Idempotent.
#
# With --statusline it also takes over the `statusLine` slot with a wrapper that
# saves Claude's session payload (which carries the usage windows and when they
# reset) and then runs whatever statusline was configured before. Opt-in,
# because that slot may already be someone's own script.
set -euo pipefail

STATUSLINE=0
STATUSLINE_DISPLAY=""
STATUSLINE_RESTORE=0
for arg in "$@"; do
  case "$arg" in
    --statusline) STATUSLINE=1 ;;
    --statusline-builtin)
      STATUSLINE=1
      STATUSLINE_DISPLAY="builtin"
      ;;
    --statusline-restore) STATUSLINE_RESTORE=1 ;;
    -h | --help)
      echo "Usage: install-claude-code.sh [--statusline | --statusline-builtin | --statusline-restore]"
      echo "  --statusline          capture Claude's usage windows via a statusline wrapper;"
      echo "                        your own statusline keeps rendering behind it"
      echo "  --statusline-builtin  same capture, but display agent-tracker's own statusline"
      echo "                        (your previous one is recorded and restored on uninstall)"
      echo "  --statusline-restore  give the statusLine slot back to what the wrapper displaced;"
      echo "                        touches nothing else and installs nothing"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done
if [ "$STATUSLINE_RESTORE" -eq 1 ] && [ "$STATUSLINE" -eq 1 ]; then
  echo "--statusline-restore cannot be combined with an install flag" >&2
  exit 2
fi
export AGENT_TRACKER_STATUSLINE_DISPLAY="$STATUSLINE_DISPLAY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Honoured here as well as in the app and the hook, because the wrapper resolves
# its own state directory the same way: if the two disagreed, the installer
# would record the displaced statusline where the wrapper never looks.
BASE_DIR="${AGENT_TRACKER_DIR:-$HOME/.agent-tracker}"
BIN_DIR="$BASE_DIR/bin"
SETTINGS="$HOME/.claude/settings.json"

# Restore-only mode: give the statusLine slot back and stop. Installs nothing,
# so it runs before any directory or script is created. The same give-back
# lives in uninstall.sh for the everything-goes path; this one exists so the
# app's Settings can turn just the statusline off.
if [ "$STATUSLINE_RESTORE" -eq 1 ]; then
  if [ ! -f "$SETTINGS" ] || ! grep -q "agent-tracker-statusline" "$SETTINGS"; then
    echo "no agent-tracker statusline wrapper in $SETTINGS — nothing to restore"
    exit 0
  fi
  cp "$SETTINGS" "$SETTINGS.agent-tracker-backup"
  python3 - << 'PYEOF'
import json
import os
import sys

base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
settings_path = os.path.expanduser("~/.claude/settings.json")
record_path = os.path.join(base, "claude-statusline-wrapped.json")

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (OSError, json.JSONDecodeError) as error:
    print(f"Cannot parse {settings_path}: {error}", file=sys.stderr)
    sys.exit(1)

current = settings.get("statusLine")
command = current.get("command") if isinstance(current, dict) else None
if not (isinstance(command, str) and "agent-tracker-statusline" in command):
    # Someone has since pointed statusLine elsewhere; that choice is theirs.
    print("statusLine no longer points at the agent-tracker wrapper — left alone")
    sys.exit(0)

# What the wrapper displaced, recorded at install time. A record saying `null`
# is PROOF the slot was empty, while no record at all proves nothing — only
# the first is safe to act on.
try:
    with open(record_path) as f:
        record = json.load(f)
    if not isinstance(record, dict) or "wrapped" not in record:
        raise ValueError("no 'wrapped' key")
    wrapped = record["wrapped"]
except (OSError, ValueError):
    print(
        f"{record_path} is missing or unreadable, so what the wrapper displaced "
        "is unknown — leaving statusLine exactly as it is rather than guessing. "
        "If you had your own statusline command it is in "
        f"{settings_path}.agent-tracker-backup; putting that line back by hand "
        "also clears the wrapper reference.",
        file=sys.stderr,
    )
    sys.exit(1)

if isinstance(wrapped, dict):
    settings["statusLine"] = wrapped
    restored = "restored your own statusLine command"
elif wrapped is None:
    del settings["statusLine"]
    restored = "removed the statusLine entry (it was empty before agent-tracker)"
else:
    print(
        f"{record_path} records a 'wrapped' value of an unexpected type "
        f"({type(wrapped).__name__}), so what the wrapper displaced cannot be "
        "trusted — leaving statusLine exactly as it is.",
        file=sys.stderr,
    )
    sys.exit(1)

# open(), never a rename: settings.json may be a symlink into a dotfiles repo.
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

try:
    os.unlink(record_path)
except OSError:
    pass

print(f"Claude Code statusline: {restored}")
PYEOF
  # set -e already propagated a python failure; reaching here means success.
  exit 0
fi

# ~/.claude may not exist yet (claude installed but never run) — the merge
# below writes settings.json into it.
mkdir -p "$BIN_DIR" "$BASE_DIR/sessions" "$HOME/.claude"
cp "$SCRIPT_DIR/agent-tracker-hook.py" "$BIN_DIR/agent-tracker-hook.py"
chmod +x "$BIN_DIR/agent-tracker-hook.py"
if [ "$STATUSLINE" -eq 1 ]; then
  # The renderer travels with the wrapper unconditionally: the display choice
  # is a one-key edit of the wrapper's record (the app offers it in Settings),
  # so the file it points at has to exist before anyone flips the key.
  cp "$SCRIPT_DIR/agent-tracker-statusline.py" "$BIN_DIR/agent-tracker-statusline.py"
  cp "$SCRIPT_DIR/agent-tracker-statusline-render.py" "$BIN_DIR/agent-tracker-statusline-render.py"
  chmod +x "$BIN_DIR/agent-tracker-statusline.py" "$BIN_DIR/agent-tracker-statusline-render.py"
fi

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.agent-tracker-backup"
  echo "Backed up $SETTINGS to $SETTINGS.agent-tracker-backup"
fi

python3 - << 'PYEOF'
import json
import os
import shlex

settings_path = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
hook = os.path.join(base, "bin", "agent-tracker-hook.py")
# Quoted: the command runs through a shell, and a home directory with a space
# in it would otherwise split into two arguments.
hook_entry = {"type": "command", "command": f"{shlex.quote(hook)} claude", "timeout": 10}

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

STATUSLINE_REFUSED=0
if [ "$STATUSLINE" -eq 1 ]; then
  # Separate python block so a refusal here (an unrecognized statusLine we will
  # not clobber) leaves the hooks above installed and reports its own reason.
  if ! python3 - << 'PYEOF'; then
import json
import os
import shlex
import sys

base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
settings_path = os.path.expanduser("~/.claude/settings.json")
wrapper = os.path.join(base, "bin", "agent-tracker-statusline.py")
record_path = os.path.join(base, "claude-statusline-wrapped.json")
# "builtin" to show agent-tracker's own statusline; empty to keep whatever the
# user had. Only ever *sets* the key: a plain --statusline re-run must not
# silently revert a builtin choice someone made earlier.
display = os.environ.get("AGENT_TRACKER_STATUSLINE_DISPLAY", "")


def set_display_builtin():
    try:
        with open(record_path) as f:
            record = json.load(f)
        if not isinstance(record, dict):
            raise ValueError("not an object")
    except (OSError, ValueError, json.JSONDecodeError):
        # No trustworthy record to edit. Never invent one: a record without a
        # real `wrapped` value is what uninstall refuses to restore from.
        print(
            f"cannot update {record_path}; the display choice was not applied",
            file=sys.stderr,
        )
        return
    record["display"] = "builtin"
    with open(record_path, "w") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print("statusline display set to agent-tracker's own")


# Written with open(), never a rename over the path: settings.json may be a
# symlink into a dotfiles repo, and replacing it would turn the link into a
# regular file.
with open(settings_path) as f:
    settings = json.load(f)

current = settings.get("statusLine")
command = current.get("command") if isinstance(current, dict) else None

if isinstance(command, str) and "agent-tracker-statusline" in command:
    # Re-recording now would store the wrapper as its own inner command, and
    # the wrapper would exec itself forever. The display choice still applies:
    # re-running with --statusline-builtin is how a keep-mine install switches.
    print("statusline wrapper already registered — nothing to do")
    if display == "builtin":
        set_display_builtin()
    sys.exit(0)

if current is not None and not (
    isinstance(current, dict)
    and current.get("type") == "command"
    and isinstance(command, str)
    and command.strip()
):
    print(
        "Refusing to touch statusLine in settings.json: it is set to something "
        "this installer does not recognize, and the wrapper can only forward a "
        f'"type": "command" statusline. Found: {json.dumps(current)}',
        file=sys.stderr,
    )
    sys.exit(1)

# What we displace, so uninstall can put it back verbatim and the wrapper knows
# what to exec. null means the slot was empty. The display key rides along:
# "builtin" makes the wrapper exec agent-tracker's own renderer instead of the
# displaced command; absent keeps whatever the user had.
record = {"schema": 1, "wrapped": current}
if display == "builtin":
    record["display"] = "builtin"
os.makedirs(base, exist_ok=True)
with open(record_path, "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")

# Only `command` changes: padding, refreshInterval and hideVimModeIndicator
# belong to the rendering the previous script still does, so they carry over.
replacement = dict(current) if isinstance(current, dict) else {"type": "command"}
replacement["command"] = shlex.quote(wrapper)
settings["statusLine"] = replacement
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if display == "builtin":
    print("Registered the statusline wrapper, showing agent-tracker's own statusline")
elif current is None:
    print("Registered the statusline wrapper (the slot was empty, so the line stays blank)")
else:
    print("Registered the statusline wrapper in front of your own statusline command")
PYEOF
    echo "The hooks are installed; only the statusline wrapper was skipped." >&2
    STATUSLINE_REFUSED=1
  fi
fi

echo "Done. New Claude Code sessions will now report their state."
echo "Note: already-running sessions pick up hooks on their next restart."

# Distinct from 1 so onboarding can report "hooks fine, statusline skipped"
# rather than a blanket failure.
if [ "$STATUSLINE_REFUSED" -eq 1 ]; then
  exit 3
fi
