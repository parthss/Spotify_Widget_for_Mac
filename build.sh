#!/bin/bash
# Builds Glass Player, installs it in ~/Applications and launches it.
# Needs Apple's Command Line Tools (xcode-select --install) or Xcode. No Xcode project required.
#
#   ./build.sh             Hardened Runtime (recommended)
#   ./build.sh --sandbox   Hardened Runtime + App Sandbox (stricter; see SECURITY.md)
#
# Uses only Apple's own tools: no downloads, no sudo. The only third-party code is the small
# vendored Now Playing adapter in Vendor/mediaremote-adapter (BSD licence; see its README),
# which lets the widget show players other than Spotify, such as Mornye.
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

# Now Playing adapter: lets the widget show and control other players (Mornye, Apple Music,
# browsers...) through macOS's Now Playing. It runs inside Apple's /usr/bin/perl, because
# since macOS 15.4 only Apple-signed programs may read Now Playing. A sandboxed app can't
# start it, so the --sandbox build leaves it out and stays Spotify-only.
if [ "$SANDBOX" = "no" ]; then
  echo "▸ Building the Now Playing adapter"
  ADAPTER_SRC="Vendor/mediaremote-adapter"
  FRAMEWORK="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
  mkdir -p "$FRAMEWORK/Versions/A/Resources"
  xcrun --sdk macosx clang \
    -O2 -fobjc-arc -fvisibility=default -dynamiclib \
    -arch "$ARCH" -mmacosx-version-min="$MIN_MACOS" \
    -I "$ADAPTER_SRC/include" -I "$ADAPTER_SRC/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    "$ADAPTER_SRC"/src/adapter/*.m "$ADAPTER_SRC"/src/private/*.m "$ADAPTER_SRC"/src/utility/*.m \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
  cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID.MediaRemoteAdapter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.7.7</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST
  ln -s A "$FRAMEWORK/Versions/Current"
  ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
  ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
  cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"
  # Nested code is signed first, then sealed into the app's own signature below.
  codesign --force --options runtime --sign - "$FRAMEWORK" >/dev/null
fi

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
pkill -f "$APP_NAME.app/Contents/Resources/mediaremote-adapter.pl" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "▸ Launching"
open "$INSTALL_DIR/$APP_NAME.app"

cat <<EOF

✓ Glass Player is on your desktop (top-left of your main display).
  • The first time it talks to Spotify, macOS asks to let it control Spotify. Click Allow.
  • Other players in Control Center's Now Playing (such as Mornye) work too, except with --sandbox.
  • Drag it anywhere. Click the album art to open Spotify. Right-click the widget for all options.
  • Bundle ID: $BUNDLE_ID
EOF
