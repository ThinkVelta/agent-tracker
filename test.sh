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
: "${AGENT_TRACKER_DIR:=${TMPDIR:-/tmp}/agent-tracker-tests}"
export AGENT_TRACKER_DIR

DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$DEV/Frameworks/Testing.framework" ] && [ ! -d /Applications/Xcode.app ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
fi
exec swift test "$@"
