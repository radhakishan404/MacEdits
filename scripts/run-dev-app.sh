#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications"
APP_BUNDLE="$APP_DIR/MacEdits Dev.app"
APP_BINARY="$ROOT_DIR/.build/debug/MacEdits"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

swift build --package-path "$ROOT_DIR"

mkdir -p "$APP_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/MacEdits"
chmod +x "$APP_BUNDLE/Contents/MacOS/MacEdits"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>MacEdits</string>
  <key>CFBundleDisplayName</key>
  <string>MacEdits</string>
  <key>CFBundleIdentifier</key>
  <string>com.macedits.dev</string>
  <key>CFBundleExecutable</key>
  <string>MacEdits</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSCameraUsageDescription</key>
  <string>MacEdits needs camera access for recording video clips.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacEdits needs microphone access for recording voice and ambient audio.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MacEdits needs speech recognition access to generate captions from your clips.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>MacEdits needs screen recording access to capture your screen for projects.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
open -n "$APP_BUNDLE"
