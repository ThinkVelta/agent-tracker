#!/bin/bash
# Runs the test suite — for real. On a Command Line Tools-only machine (no
# Xcode.app), plain `swift test` builds but silently executes ZERO tests:
# SwiftPM's test runner can't resolve the CLT-bundled Testing.framework without
# explicit framework/rpath flags (see the Package.swift header). This wrapper
# adds them when needed so a green run always means the tests actually ran.
set -euo pipefail
cd "$(dirname "$0")"

# Keep the suite out of the real ~/.agent-tracker. Both SessionStore and
# DebugLog resolve their paths from this variable — DebugLog's own comment says
# it is what makes tests hermetic — but nothing ever set it, so every run
# appended its fixtures to the log a user reads to diagnose a real delivery.
# Measured before this line existed: 1468 polluted lines, the tail of them
# synthetic usage-limit readings with a reset date in the past.
#
# A fresh directory per run, so nothing carries over and two runs on one machine
# cannot collide. An explicit AGENT_TRACKER_DIR still wins and is left alone —
# only a directory this script created is a directory this script deletes.
SCRATCH=""
if [ -z "${AGENT_TRACKER_DIR:-}" ]; then
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/agent-tracker-tests.XXXXXX")"
  AGENT_TRACKER_DIR="$SCRATCH"
fi
export AGENT_TRACKER_DIR

DEV=/Library/Developer/CommandLineTools/Library/Developer
ARGS=(swift test)
if [ -d "$DEV/Frameworks/Testing.framework" ] && [ ! -d /Applications/Xcode.app ]; then
  ARGS+=(
    -Xswiftc -F -Xswiftc "$DEV/Frameworks"
    -Xlinker -F"$DEV/Frameworks"
    -Xlinker -rpath -Xlinker "$DEV/Frameworks"
    -Xlinker -rpath -Xlinker "$DEV/usr/lib"
  )
fi

# Run rather than exec, which this used to do: `exec` replaces the shell, and it
# would take any cleanup with it — an EXIT trap included. The suite's exit status
# is this script's contract, so it is captured and re-raised by hand.
STATUS=0
"${ARGS[@]}" "$@" || STATUS=$?
[ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
exit "$STATUS"
