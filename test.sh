#!/bin/bash
# Runs the test suite — for real. On a Command Line Tools-only machine (no
# Xcode.app), plain `swift test` builds but silently executes ZERO tests:
# SwiftPM's test runner can't resolve the CLT-bundled Testing.framework without
# explicit framework/rpath flags (see the Package.swift header). This wrapper
# adds them when needed so a green run always means the tests actually ran.
set -euo pipefail
cd "$(dirname "$0")"

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
