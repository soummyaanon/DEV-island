#!/usr/bin/env bash
# `swift test`, with one fix for a Command Line Tools install: the Swift
# Testing macros (#expect, @Test) ship in plugins/testing/, which SwiftPM
# doesn't search there. With Xcode selected the flag is harmless.
set -euo pipefail

cd "$(dirname "$0")/.."
plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
