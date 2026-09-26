#!/usr/bin/env bash
# Renders the app icon with the island's own bot renderer and packs it into
# Resources/AppIcon.icns (bundle.sh copies it in).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/AgentIsland"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$bin" --render-icon "$work/master.png"
set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/master.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$work/master.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
