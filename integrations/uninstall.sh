#!/bin/bash
# Removes the agent-tracker integrations: surgically strips agent-tracker hook
# commands from ~/.claude/settings.json (hook-level, so third-party hooks
# sharing an entry survive) and the agent-tracker notify setting from
# ~/.codex/config.toml (single- or multi-line form), backing each file up first
# and leaving everything else intact. The two sections are independent — a
# broken config in one never blocks cleaning the other. Idempotent. Session
# data in ~/.agent-tracker is kept unless --purge.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h | --help)
      echo "Usage: uninstall.sh [--purge]"
      echo "  --purge  also remove ~/.agent-tracker (hook script + session data)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

SETTINGS="$HOME/.claude/settings.json"
CONFIG="$HOME/.codex/config.toml"
DATA_DIR="${AGENT_TRACKER_DIR:-$HOME/.agent-tracker}"
FAILED=0

# Backed up at most once: the hook and statusline sections both edit
# settings.json, and a second copy would capture the first one's output.
BACKED_UP=0
backup_settings() {
  if [ "$BACKED_UP" -eq 0 ]; then
    cp "$SETTINGS" "$SETTINGS.agent-tracker-uninstall-backup"
    echo "Backed up $SETTINGS to $SETTINGS.agent-tracker-uninstall-backup"
    BACKED_UP=1
  fi
}

# --- Claude Code: remove agent-tracker hook commands -------------------------
if [ -f "$SETTINGS" ] && grep -q "agent-tracker-hook" "$SETTINGS"; then
  backup_settings
  if ! python3 - << 'PYEOF'; then
import json
import os
import sys

settings_path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (OSError, json.JSONDecodeError) as error:
    print(f"Cannot parse {settings_path}: {error}", file=sys.stderr)
    sys.exit(1)

# Filter at the hook level, not the entry level: an entry whose hooks array
# mixes agent-tracker with another tool's hook must keep the other tool's.
removed = []
hooks = settings.get("hooks", {})
for event in list(hooks):
    entries = hooks[event]
    changed = False
    kept_entries = []
    for entry in entries:
        inner = entry.get("hooks", [])
        kept_inner = [h for h in inner if "agent-tracker-hook" not in h.get("command", "")]
        if len(kept_inner) == len(inner):
            kept_entries.append(entry)
            continue
        changed = True
        if kept_inner:
            entry = dict(entry)
            entry["hooks"] = kept_inner
            kept_entries.append(entry)
        # else: entry only contained agent-tracker hooks — drop it entirely.
    if not changed:
        continue
    removed.append(event)
    if kept_entries:
        hooks[event] = kept_entries
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
    echo "WARNING: Claude Code cleanup failed — fix $SETTINGS and re-run. Continuing with Codex." >&2
    FAILED=1
  fi
else
  echo "Claude Code: no agent-tracker hooks in $SETTINGS — nothing to do"
fi

# --- Claude Code: give the statusLine slot back -------------------------------
if [ -f "$SETTINGS" ] && grep -q "agent-tracker-statusline" "$SETTINGS"; then
  backup_settings
  if ! python3 - << 'PYEOF'; then
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

# What the wrapper displaced, recorded at install time. Absent means we cannot
# prove what was there, and inventing a command is worse than leaving the slot
# empty — which is what Claude Code defaults to anyway.
wrapped = None
try:
    with open(record_path) as f:
        record = json.load(f)
    if isinstance(record, dict) and isinstance(record.get("wrapped"), dict):
        wrapped = record["wrapped"]
except (OSError, json.JSONDecodeError):
    pass

if wrapped is None:
    del settings["statusLine"]
    restored = "removed the statusLine entry (it was empty before agent-tracker)"
else:
    settings["statusLine"] = wrapped
    restored = "restored your own statusLine command"

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
    echo "WARNING: statusline cleanup failed — fix $SETTINGS and re-run." >&2
    FAILED=1
  fi
else
  echo "Claude Code: no agent-tracker statusline wrapper in $SETTINGS — nothing to do"
fi

# --- Codex: remove the agent-tracker notify setting --------------------------
if [ -f "$CONFIG" ] && grep -q "agent-tracker-hook" "$CONFIG"; then
  cp "$CONFIG" "$CONFIG.agent-tracker-uninstall-backup"
  echo "Backed up $CONFIG to $CONFIG.agent-tracker-uninstall-backup"
  if ! python3 - << 'PYEOF'; then
import os
import re
import sys

config_path = os.path.expanduser("~/.codex/config.toml")
try:
    with open(config_path) as f:
        lines = f.readlines()
except OSError as error:
    print(f"Cannot read {config_path}: {error}", file=sys.stderr)
    sys.exit(1)

# The notify array may have been reformatted across multiple lines; consume the
# whole `notify = [ ... ]` block (bracket-balanced) and drop it only when it
# mentions the agent-tracker hook.
kept = []
removed = 0
i = 0
while i < len(lines):
    line = lines[i]
    # Exact `notify` key only — never `notifications`, `notify_channel`, ….
    if re.match(r"[ \t]*notify[ \t]*=", line):
        block = [line]
        depth = line.count("[") - line.count("]")
        j = i + 1
        while depth > 0 and j < len(lines):
            block.append(lines[j])
            depth += lines[j].count("[") - lines[j].count("]")
            j += 1
        if any("agent-tracker-hook" in b for b in block):
            removed += len(block)
            i += len(block)
            continue
        kept.extend(block)
        i += len(block)
        continue
    kept.append(line)
    i += 1

with open(config_path, "w") as f:
    f.writelines(kept)

if removed:
    print(f"Removed the agent-tracker notify setting from {config_path}")
else:
    # grep matched but no removable block found — never claim success.
    print(
        f"Found 'agent-tracker-hook' in {config_path} but not as a notify "
        "setting — please remove it manually.",
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
    echo "WARNING: Codex cleanup failed — check $CONFIG manually." >&2
    FAILED=1
  fi
else
  echo "Codex: no agent-tracker notify setting in $CONFIG — nothing to do"
fi

# --- Installed app bundle ----------------------------------------------------
# `make install` places AgentTracker.app in /Applications (or ~/Applications).
# Removing it also disables its start-at-login registration — launchd drops a
# login item whose bundle is gone.
BUNDLE_ID="com.thinkvelta.agent-tracker"
for APP in "/Applications/AgentTracker.app" "$HOME/Applications/AgentTracker.app"; do
  if [ -d "$APP" ]; then
    if pgrep -x AgentTracker > /dev/null 2>&1; then
      echo "Stopping the running AgentTracker"
      pkill -x AgentTracker || true
      sleep 1
    fi
    # Tolerant like every other section: an unwritable /Applications must not
    # abort the remaining cleanup under set -e.
    if rm -rf "$APP" 2> /dev/null; then
      echo "Removed $APP"
    else
      echo "WARNING: could not remove $APP (permissions?) — remove it manually." >&2
      FAILED=1
    fi
  fi
done
# The preferences domain (onboarding-completed flag, future settings). Guarded:
# `defaults delete` on a missing domain exits non-zero, which is not a failure.
if defaults read "$BUNDLE_ID" > /dev/null 2>&1; then
  defaults delete "$BUNDLE_ID"
  echo "Removed the $BUNDLE_ID preferences domain"
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

if [ "$FAILED" -eq 1 ]; then
  echo "Done with warnings — one of the configs needs manual attention (see above)." >&2
  exit 1
fi
echo "Done. Restart any running agent sessions to stop them reporting state."
