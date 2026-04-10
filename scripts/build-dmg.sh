#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/dmg-stage"
APP_NAME="${APP_NAME:-MacEdits}"
BUNDLE_ID="${BUNDLE_ID:-com.macedits.app}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OPEN_AFTER_BUILD="${OPEN_AFTER_BUILD:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --open)
      OPEN_AFTER_BUILD=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--version x.y.z] [--build-number n] [--bundle-id id] [--open]" >&2
      exit 1
      ;;
  esac
done

echo "==> Building release binary"
swift build --configuration release --package-path "$ROOT_DIR"

BIN_PATH="$BUILD_DIR/MacEdits"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Release binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Preparing app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE" "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$STAGE_DIR"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
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

echo "==> Code signing app bundle (identity: $SIGN_IDENTITY)"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "==> Staging DMG contents"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating DMG at $DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "DMG generated: $DMG_PATH"
if [[ "$OPEN_AFTER_BUILD" == "1" ]]; then
  open "$DMG_PATH"
fi
