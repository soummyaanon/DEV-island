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
DMG="$RELEASE/Agent Island-$VERSION-arm64.dmg"

echo "==> Building daemon + app"
pnpm --filter @agent-island/daemon build
pnpm --filter @agent-island/app build

echo "==> Packaging .app (electron-builder --dir)"
pnpm --filter @agent-island/app run pack

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

hdiutil create -volname "Agent Island" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG"
