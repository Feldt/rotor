#!/bin/zsh
# Renders the icon from code (scripts/render-icon.swift) and builds Resources/AppIcon.icns.
# Also exports docs/icon.png and docs/menubar.png.
set -euo pipefail
cd "${0:A:h}/.."
T="$(mktemp -d)"
swift scripts/render-icon.swift "$T/icon-1024.png" docs/menubar.png
cp "$T/icon-1024.png" docs/icon.png
SET="$T/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$T"
echo "Resources/AppIcon.icns"
