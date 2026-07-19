#!/usr/bin/env bash
# Build the distributable DMG: daemon + app -> packaged .app -> DMG.
# CI supplies Developer ID + notarization credentials. Local builds fall back
# to ad-hoc signing so they remain launchable on the developer's own machine.
set -euo pipefail

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

echo "==> Assembling DMG"
STAGE="$RELEASE/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Retina background (1x + 2x combined into one TIFF Finder scales correctly).
# No README in the window — the background art carries the Gatekeeper hint.
mkdir -p "$STAGE/.background"
tiffutil -cathidpicheck "$ROOT/scripts/dmg/background.png" "$ROOT/scripts/dmg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

echo "==> Styling the DMG window (Finder)"
RW="$RELEASE/rw.dmg"
rm -f "$RW"
# Versioned volume name: Finder remembers window geometry per volume, so a
# fresh name per release guarantees every user's window opens at OUR size.
hdiutil create -volname "Agent Island $VERSION" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $3}')
# Style the volume we actually mounted — a stale "Agent Island" volume from a
# user-opened DMG would otherwise steal the name (mounts as "Agent Island 1").
VOLNAME=$(basename "$MOUNT")

# Best-effort: a styling failure still ships a working (plain) DMG.
if ! /usr/bin/osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Agent Island.app" of container window to {165, 200}
    set position of item "Applications" of container window to {475, 200}
    set the bounds of container window to {200, 120, 840, 548}
    update without registering applications
    delay 3
    set the bounds of container window to {200, 120, 840, 548}
    close
  end tell
end tell
OSA
then
  echo "    (styling failed — shipping an unstyled DMG)"
fi
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

echo "✓ $DMG"
