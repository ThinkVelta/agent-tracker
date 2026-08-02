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
render() {
  local view="$1" appearance="$2" target="$3"
  AGENT_TRACKER_DIR="$STAGE/state" \
    AGENT_TRACKER_CLAUDE_DIR="$STAGE/claude" \
    AGENT_TRACKER_CODEX_DIR="$STAGE/codex" \
    "$BINARY" --render-preview "$OUT/$target" --view "$view" --appearance "$appearance" \
    > /dev/null 2>&1
  echo "    $OUT/$target"
}

echo "==> rendering"
render popover light dropdown-light.png
render popover dark dropdown-dark.png
render menubar light menubar-light.png
render menubar dark menubar-dark.png
render icons light icon-modes-light.png
render icons dark icon-modes-dark.png

echo "==> done"
