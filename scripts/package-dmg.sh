#!/usr/bin/env bash
# Build the distributable DMG: daemon + app -> packaged .app -> deep ad-hoc
# sign (unsigned apps read "damaged" on Apple Silicon) -> DMG with first-launch
# instructions inside. One command: pnpm package
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

# electron-builder's electronLanguages only trims app-level lproj on macOS;
# the Electron Framework ships ~55 locale.pak (~42MB) that Chromium happily
# lives without (missing locale falls back to en). Trim BEFORE signing.
echo "==> Trimming Electron Framework locales (en only)"
FW_RES="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
find "$FW_RES" -maxdepth 1 -name "*.lproj" ! -name "en*.lproj" -exec rm -rf {} +

echo "==> Deep ad-hoc signing the bundle"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "    signature OK"

echo "==> Assembling DMG"
STAGE="$RELEASE/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
AGENT ISLAND — FIRST LAUNCH (one time only)
===========================================

1. Drag "Agent Island" onto the "Applications" folder in this window.

2. Open Agent Island once. macOS will say it "could not verify" the app.
   Click "Done"  (NOT "Move to Bin").

3. Open  System Settings > Privacy & Security  and scroll down to Security.

4. Next to the Agent Island message, click "Open Anyway" and confirm.

5. That's it — it opens normally from now on.
   The island appears around your MacBook notch, and Claude Code is
   configured automatically on first launch.

Why this dance? Agent Island isn't notarized by Apple (yet), so macOS
asks once. Everything runs 100% locally on your Mac — no cloud, no
accounts, no telemetry.

Terminal alternative (skips steps 2–4):
  xattr -cr "/Applications/Agent Island.app"
EOF

# Retina background (1x + 2x combined into one TIFF Finder scales correctly).
mkdir -p "$STAGE/.background"
tiffutil -cathidpicheck "$ROOT/scripts/dmg/background.png" "$ROOT/scripts/dmg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

echo "==> Styling the DMG window (Finder)"
RW="$RELEASE/rw.dmg"
rm -f "$RW"
hdiutil create -volname "Agent Island" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
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
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Agent Island.app" of container window to {160, 195}
    set position of item "Applications" of container window to {480, 195}
    set position of item "READ ME FIRST.txt" of container window to {320, 330}
    close
    open
    update without registering applications
    delay 2
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
