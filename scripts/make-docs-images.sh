#!/bin/bash
# Regenerates the README's images from synthetic data.
#
# Runs the app's own --render-preview mode against a throwaway state directory,
# so what lands in assets/ is the real UI drawing invented sessions — never a
# screenshot of whatever the author happened to be running. Re-run this after
# any change to the dropdown and commit the result.
#
# Caveat inherited from --render-preview: ImageRenderer does not rasterize
# AppKit-backed views, so the search field appears as a placeholder bar and the
# panel's translucent material is absent. The layout and states are faithful;
# the chrome is flat.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="assets"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> building"
swift build -c release > /dev/null
BINARY="$(swift build -c release --show-bin-path)/AgentTracker"

echo "==> synthesizing sessions"
python3 scripts/demo-sessions.py "$STAGE/state" > /dev/null
# Empty overrides for the two live scanners: without these the render would
# pick up the real Claude registry and Codex rollouts on this machine.
mkdir -p "$STAGE/claude/sessions" "$STAGE/codex"

mkdir -p "$OUT"
# `--render-preview` logs "render failed" and still exits 0, so a broken render
# would leave the previous image in place and this script would report success —
# the failure mode where the README quietly documents an old UI forever. Delete
# the target first so a stale file cannot stand in for a fresh one, and keep the
# render's own output to show only if something goes wrong.
render() {
  local view="$1" appearance="$2" target="$3"
  local path="$OUT/$target"
  local log="$STAGE/render.log"

  rm -f "$path"
  if ! AGENT_TRACKER_DIR="$STAGE/state" \
    AGENT_TRACKER_CLAUDE_DIR="$STAGE/claude" \
    AGENT_TRACKER_CODEX_DIR="$STAGE/codex" \
    "$BINARY" --render-preview "$path" --view "$view" --appearance "$appearance" \
    > "$log" 2>&1; then
    cat "$log" >&2
    echo "render exited non-zero: $path" >&2
    exit 1
  fi
  if [ ! -s "$path" ]; then
    cat "$log" >&2
    echo "render produced no image: $path" >&2
    exit 1
  fi
  echo "    $path"
}

echo "==> rendering"
render popover light dropdown-light.png
render popover dark dropdown-dark.png
render menubar light menubar-light.png
render menubar dark menubar-dark.png
render icons light icon-modes-light.png
render icons dark icon-modes-dark.png

echo "==> done"
