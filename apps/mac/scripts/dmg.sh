#!/usr/bin/env bash
# The release DMG: builds "Agent Island.app" (bundle.sh ship) and packs it into
# build/Agent-Island.dmg, the asset name 1.x's updater and the site download.
# With CODESIGN_IDENTITY and NOTARY_* set (the release workflow's secrets) the
# app is Developer ID signed and the DMG notarised; without them, ad-hoc, as 1.x.
set -euo pipefail
trap 'echo "==> dmg failed at line $LINENO: $BASH_COMMAND" >&2' ERR

cd "$(dirname "$0")/.."
./scripts/bundle.sh ship
app="build/Agent Island.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
codesign --verify --deep --strict "$app"
echo "    signature OK"

# The same window as 1.x's: its background art, icon positions and styling.
../../scripts/dmg/assemble.sh "$app" "$version" "build/Agent-Island.dmg"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "build/Agent-Island.dmg"
  if [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
    echo "==> Notarising"
    xcrun notarytool submit "build/Agent-Island.dmg" --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
    xcrun stapler staple "build/Agent-Island.dmg"
  fi
fi
echo "✓ build/Agent-Island.dmg ($version)"
