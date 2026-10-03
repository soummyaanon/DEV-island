#!/usr/bin/env bash
# Builds the app bundle into apps/mac/build/. A bundle is what gives the app
# its id (single instance, login item, TCC); `swift run` has none.
#
#   apps/mac/scripts/bundle.sh            release build, "Agent Island Next.app"
#   apps/mac/scripts/bundle.sh debug      debug build (keeps "Play Charger Moment")
#   apps/mac/scripts/bundle.sh ship       the release: "Agent Island.app", with
#                                         1.x's id so it replaces 1.x in place
#   apps/mac/scripts/bundle.sh --open     …and launch it
set -euo pipefail

cd "$(dirname "$0")/.."
config=release
open_after=false
ship=false
for arg in "$@"; do
  case "$arg" in
    debug) config=debug ;;
    ship) ship=true ;;
    --open) open_after=true ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

swift build -c "$config" --arch arm64
bin="$(swift build -c "$config" --arch arm64 --show-bin-path)/AgentIsland"

if $ship; then
  app="build/Agent Island.app"
else
  app="build/Agent Island Next.app"
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/AgentIsland"
cp Resources/Info.plist "$app/Contents/Info.plist"
if $ship; then
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.agentisland.app" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Agent Island" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Agent Island" "$plist"
fi
mkdir -p "$app/Contents/Resources"
cp -R Resources/Sounds "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# A Developer ID when the release workflow has one (CODESIGN_IDENTITY), with
# the hardened runtime notarisation needs; ad-hoc otherwise, as 1.x ships.
dev_keychain="$HOME/Library/Keychains/agent-island-dev.keychain-db"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/entitlements.plist --sign "$CODESIGN_IDENTITY" "$app"
elif ! $ship && [[ -f "$dev_keychain" ]] && security find-certificate -c "Agent Island Dev" "$dev_keychain" >/dev/null 2>&1; then
  # A stable local identity (scripts/dev-signing.sh): privacy grants survive rebuilds.
  security unlock-keychain -p "" "$dev_keychain" 2>/dev/null || true
  codesign --force --keychain "$dev_keychain" --sign "Agent Island Dev" "$app"
else
  codesign --force --sign - "$app"
fi
echo "built $app ($config)"

if $open_after; then
  # One instance at a time: quit a running copy first.
  pkill -x AgentIsland 2>/dev/null || true
  open "$app"
fi
