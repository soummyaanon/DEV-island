#!/usr/bin/env bash
# Build the distributable DMG: daemon + app -> packaged .app -> DMG.
# CI supplies Developer ID + notarization credentials. Local builds fall back
# to ad-hoc signing so they remain launchable on the developer's own machine.
set -euo pipefail
# A release that dies must say where: several steps below are quiet by design.
trap 'echo "==> package-dmg failed at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/packages/app"
RELEASE="$APP_DIR/release"
APP="$RELEASE/mac-arm64/Agent Island.app"
VERSION="$(node -p "require('$APP_DIR/package.json').version")"
# Version lives in the release tag, not the filename — and no spaces, so
# GitHub asset names stay verbatim.
DMG="$RELEASE/Agent-Island.dmg"

echo "==> Building daemon + app"
pnpm --filter @agent-island/daemon build
pnpm --filter @agent-island/app build

echo "==> Packaging .app (electron-builder --dir)"
pnpm --filter @agent-island/app run pack

# Never overwrite CI's Developer ID signature. Local builds have no signing
# identity, so apply an ad-hoc signature only when CSC_LINK is absent.
if [[ -z "${CSC_LINK:-}" ]]; then
  echo "==> Ad-hoc signing local build"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "    signature OK"

"$ROOT/scripts/dmg/assemble.sh" "$APP" "$VERSION" "$DMG"

echo "✓ $DMG"
