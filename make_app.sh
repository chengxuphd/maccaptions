#!/bin/bash
# Builds MacCaptions.app (ad-hoc signed) next to this script.
# Usage: ./make_app.sh            (VERSION=1.2.3 ./make_app.sh to set the version shown in Finder)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product MacCaptions
BIN=$(swift build -c release --show-bin-path)/MacCaptions
APP=MacCaptions.app
VERSION=${VERSION:-0.1.0}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacCaptions"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.chengxuphd.maccaptions</string>
    <key>CFBundleName</key><string>MacCaptions</string>
    <key>CFBundleDisplayName</key><string>MacCaptions</string>
    <key>CFBundleExecutable</key><string>MacCaptions</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.4</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MacCaptions captions your microphone.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>MacCaptions transcribes speech on-device.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MacCaptions captions system audio (meetings, videos).</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier io.github.chengxuphd.maccaptions "$APP"
echo "Built $(pwd)/$APP"
