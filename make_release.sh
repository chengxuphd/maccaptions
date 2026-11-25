#!/bin/bash
# Builds the app and the release files in dist/:  MacCaptions-<version>-macos-arm64.{dmg,zip} + .sha256
# Usage: VERSION=0.1.2 ./make_release.sh
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-0.1.0}
export VERSION
./make_app.sh
NAME="MacCaptions-$VERSION-macos-arm64"
mkdir -p dist && rm -f "dist/$NAME".*

ditto -c -k --sequesterRsrc --keepParent MacCaptions.app "dist/$NAME.zip"

# DMG: the app next to an Applications shortcut, with the app icon on the mounted volume
STAGE=$(mktemp -d)
ditto MacCaptions.app "$STAGE/MacCaptions.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
hdiutil create -volname "MacCaptions" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$STAGE.rw.dmg" >/dev/null
MP=$(mktemp -d)
hdiutil attach "$STAGE.rw.dmg" -nobrowse -mountpoint "$MP" >/dev/null
SetFile -a C "$MP"                      # mark the volume as having a custom icon
hdiutil detach "$MP" >/dev/null
hdiutil convert "$STAGE.rw.dmg" -format UDZO -o "dist/$NAME.dmg" >/dev/null
rm -rf "$STAGE" "$STAGE.rw.dmg"; rmdir "$MP" 2>/dev/null || true

(cd dist && for f in "$NAME.dmg" "$NAME.zip"; do shasum -a 256 "$f" > "$f.sha256"; done; ls -la "$NAME".*)
