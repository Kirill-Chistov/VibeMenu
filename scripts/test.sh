#!/usr/bin/env bash
#
# Run the VibeMenu test suite.
#
# Swift Testing (`import Testing`) ships with both full Xcode and the standalone
# Command Line Tools. However, when ONLY the Command Line Tools are installed, SPM
# does not automatically add the Testing.framework / interop-dylib search paths, so
# `swift test` fails to compile/link/load the tests. This wrapper adds those paths
# in that case; with full Xcode installed it just runs `swift test`.
#
# Usage: scripts/test.sh [extra swift test args]
set -euo pipefail

DEV="$(xcode-select -p)"

if [[ "$DEV" == *"CommandLineTools"* ]]; then
  FWPATH="$DEV/Library/Developer/Frameworks"      # Testing.framework
  LIBPATH="$DEV/Library/Developer/usr/lib"        # lib_TestingInterop.dylib
  exec swift test \
    -Xswiftc -F -Xswiftc "$FWPATH" \
    -Xlinker -F -Xlinker "$FWPATH" \
    -Xlinker -rpath -Xlinker "$FWPATH" \
    -Xlinker -rpath -Xlinker "$LIBPATH" \
    "$@"
else
  exec swift test "$@"
fi
