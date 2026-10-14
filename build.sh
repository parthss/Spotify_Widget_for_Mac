#!/bin/bash
# Builds Glass Player, installs it in ~/Applications and launches it.
# Needs Apple's Command Line Tools (xcode-select --install) or Xcode. No Xcode project required.
#
#   ./build.sh             Hardened Runtime (recommended)
#   ./build.sh --sandbox   Hardened Runtime + App Sandbox (stricter; see SECURITY.md)
#
# Uses only Apple's own tools: no downloads, no third-party code, no sudo.
set -euo pipefail
cd "$(dirname "$0")"

ENTITLEMENTS="Resources/GlassPlayer.entitlements"
SANDBOX="no"
case "${1:-}" in
  "") ;;
  --sandbox) ENTITLEMENTS="Resources/GlassPlayer-Sandbox.entitlements"; SANDBOX="yes" ;;
  *) echo "Unknown option: $1 (use --sandbox or nothing)" >&2; exit 1 ;;
esac

APP_NAME="Glass Player"
EXECUTABLE="GlassPlayer"
BUNDLE_ID="local.glassplayer"
MIN_MACOS="14.0"
BUILD_DIR=".build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Apple's Command Line Tools, then run this again:"
  echo "    xcode-select --install"
  exit 1
fi

ARCH="$(uname -m)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
echo "▸ Building $APP_NAME ($ARCH, macOS SDK $SDK_VERSION)"
if [ "${SDK_VERSION%%.*}" -lt 26 ]; then
  echo "  Note: this SDK predates macOS 26, so the widget will use a frosted blur instead of"
  echo "  Liquid Glass. Update Command Line Tools / Xcode to 26 or later to get Liquid Glass."
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -wmo compiles every file in one pass, so any errors are all reported together.
xcrun --sdk macosx swiftc \
  -O -wmo \
  -swift-version 5 \
  -parse-as-library \
  -module-name "$EXECUTABLE" \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXECUTABLE"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign for this Mac with the Hardened Runtime (blocks code injection into the app).
# Default entitlement: permission to send Apple Events to control Spotify, nothing else.
codesign --force --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"
SIGNATURE="$(codesign -dv "$APP" 2>&1)"
case "$SIGNATURE" in
  *runtime*) echo "▸ Signed with Hardened Runtime" ;;
  *) echo "Signing didn't enable the Hardened Runtime. Stopping." >&2; exit 1 ;;
esac
if [ "$SANDBOX" = "yes" ]; then
  GRANTED="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
  case "$GRANTED" in
    *app-sandbox*) echo "▸ App Sandbox on" ;;
    *) echo "Signing didn't enable the App Sandbox. Stopping." >&2; exit 1 ;;
  esac
fi

echo "▸ Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
pkill -x "$EXECUTABLE" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "▸ Launching"
open "$INSTALL_DIR/$APP_NAME.app"

cat <<EOF

✓ Glass Player is on your desktop (top-left of your main display).
  • The first time it talks to Spotify, macOS asks to let it control Spotify. Click Allow.
  • Drag it anywhere. Click the album art to open Spotify. Right-click the widget for all options.
  • Bundle ID: $BUNDLE_ID
EOF
