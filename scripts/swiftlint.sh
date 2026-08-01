#!/bin/bash
# swiftlint passthrough that works on Command Line Tools-only machines: the
# portable swiftlint binary needs SourceKit, and without Xcode.app it cannot
# locate the CLT-bundled sourcekitdInProc on its own (it dies with "Loading
# sourcekitdInProc failed"). Pointing DYLD_FRAMEWORK_PATH at the CLT lib dir
# fixes that. With Xcode installed — or on Linux CI — this is a plain exec.
set -euo pipefail

CLT_LIB="/Library/Developer/CommandLineTools/usr/lib"
if [ ! -d /Applications/Xcode.app ] && [ -d "$CLT_LIB/sourcekitdInProc.framework" ]; then
  export DYLD_FRAMEWORK_PATH="$CLT_LIB${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
fi
exec swiftlint "$@"
