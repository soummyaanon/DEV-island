#!/usr/bin/env bash
# Compile the native sidecar (haptics; CoreLocation in a later stage).
#
# Deliberately NEVER fails the build — except for releases, which set
# AGENT_ISLAND_REQUIRE_NATIVE=1 so a DMG can't ship without the helper. A contributor without Xcode CLT, a
# non-macOS checkout, or a broken toolchain must still get a working app —
# main/native-helper.ts treats a missing binary as a normal state and the
# features that need it degrade to no-ops.
set -uo pipefail

# Degrade (exit 0) for contributors; fail loudly for a release build.
soft_fail() {
  if [[ "${AGENT_ISLAND_REQUIRE_NATIVE:-}" == "1" ]]; then
    echo "==> AGENT_ISLAND_REQUIRE_NATIVE=1: refusing to continue without the native helper" >&2
    exit 1
  fi
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/native/AgentIslandNative.swift"
PLIST="$ROOT/native/Info.plist"
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
  soft_fail
fi

# Skip the ~2s compile when neither input has changed since the last build.
if [[ -f "$OUT" && "$OUT" -nt "$SRC" && "$OUT" -nt "$PLIST" ]]; then
  echo "==> Native helper up to date"
  exit 0
fi

# The embedded __info_plist section IS this binary's Info.plist: CoreLocation
# refuses to run without a usage description in Bundle.main, and a bare Mach-O
# tool has no bundle directory to read one from.
# Foundation Models (the on-device Apple Intelligence model) exists only in the
# macOS 26 SDK and later. Weak-linked, so the same binary still launches on
# macOS 12–15 and simply reports the assistant unavailable; on an older SDK the
# Swift source compiles that section out and there is nothing to link.
EXTRA=()
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -n "$SDK" && -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]]; then
  EXTRA+=(-Xlinker -weak_framework -Xlinker FoundationModels)
fi

echo "==> Building native helper (arm64)"
if ! swiftc -O -target arm64-apple-macos12 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -o "$OUT" "$SRC"; then
  echo "==> Native helper failed to build — haptics will be inert" >&2
  rm -f "$OUT"
  soft_fail
fi

# Prove the protocol works before we ship it: a helper that compiles but can't
# answer is worse than one that's absent, because the parent waits on it.
if [[ "$(echo ping | "$OUT" 2>/dev/null)" != "pong" ]]; then
  echo "==> Native helper built but failed its smoke test — removing" >&2
  rm -f "$OUT"
  soft_fail
fi

echo "    $OUT"
