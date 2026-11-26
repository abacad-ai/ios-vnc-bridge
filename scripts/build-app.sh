#!/usr/bin/env bash
# Build "iOS VNC Bridge.app" and, with DMG=1, a DMG beside it.
#
#   ./scripts/build-app.sh                 # build/ iOS VNC Bridge.app
#   DMG=1 ./scripts/build-app.sh           # + build/iOS-VNC-Bridge-0.1.0.dmg
#
# Signing: with CODESIGN_ID set (a Developer ID Application identity) the app is
# signed with the hardened runtime, ready for notarization. Without it the app is
# ad-hoc signed, which runs locally but is not distributable.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=${VERSION:-0.1.0}
APP_NAME="iOS VNC Bridge"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

echo "==> engine (Go)"
mkdir -p "$BUILD"
go build -trimpath -ldflags "-s -w" -o "$BUILD/engine" ./cmd/engine

echo "==> app (Swift)"
swift build -c release --package-path app
SWIFT_BIN="$ROOT/app/.build/release/IOSVNCBridge"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge"
cp "$SWIFT_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD/engine" "$APP/Contents/Resources/engine"
cp "$ROOT/bridge/iosbridge.py" "$APP/Contents/Resources/bridge/iosbridge.py"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/engine"

echo "==> sign"
if [[ -n "${CODESIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP/Contents/Resources/engine"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --sign - "$APP/Contents/Resources/engine"
  codesign --force --sign - "$APP"
fi

echo "built $APP"
du -sh "$APP"

if [[ "${DMG:-0}" == "1" ]]; then
  echo "==> dmg"
  DMG_PATH="$BUILD/iOS-VNC-Bridge-$VERSION.dmg"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "built $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
fi

if [[ -n "${NOTARIZE:-}" ]]; then
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
  echo "==> notarize"
  xcrun notarytool submit "$BUILD/iOS-VNC-Bridge-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$BUILD/iOS-VNC-Bridge-$VERSION.dmg"
  echo "notarized and stapled"
fi
