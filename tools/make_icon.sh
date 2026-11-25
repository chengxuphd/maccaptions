#!/bin/bash
# Regenerates Resources/AppIcon.icns (and docs/icon.png for the README) from tools/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift tools/make_icon.swift "$TMP/AppIcon.iconset"
mkdir -p Resources docs
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_256x256@2x.png" docs/icon.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns and docs/icon.png"
