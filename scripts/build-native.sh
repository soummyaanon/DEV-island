#!/usr/bin/env bash
# Compile the native sidecar (haptics; CoreLocation in a later stage).
#
# Deliberately NEVER fails the build. A contributor without Xcode CLT, a
# non-macOS checkout, or a broken toolchain must still get a working app —
# main/native-helper.ts treats a missing binary as a normal state and the
# features that need it degrade to no-ops.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/native/AgentIslandNative.swift"
OUT_DIR="$ROOT/packages/app/native"
OUT="$OUT_DIR/AgentIslandNative"

# Always present, possibly empty: electron-builder copies this directory as an
# extraResource, and a missing path would fail the pack step.
mkdir -p "$OUT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "==> Skipping native helper (not macOS)"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "==> Skipping native helper (swiftc not found — haptics will be inert)"
  echo "    Install Xcode Command Line Tools: xcode-select --install"
  exit 0
fi

# Skip the ~2s compile when the source hasn't changed since the last build.
if [[ -f "$OUT" && "$OUT" -nt "$SRC" ]]; then
  echo "==> Native helper up to date"
  exit 0
fi

echo "==> Building native helper (arm64)"
if ! swiftc -O -target arm64-apple-macos12 -o "$OUT" "$SRC"; then
  echo "==> Native helper failed to build — haptics will be inert" >&2
  rm -f "$OUT"
  exit 0
fi

# Prove the protocol works before we ship it: a helper that compiles but can't
# answer is worse than one that's absent, because the parent waits on it.
if [[ "$(echo ping | "$OUT" 2>/dev/null)" != "pong" ]]; then
  echo "==> Native helper built but failed its smoke test — removing" >&2
  rm -f "$OUT"
  exit 0
fi

echo "    $OUT"
