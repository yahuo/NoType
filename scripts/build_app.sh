#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
APP_NAME="NoType.app"
LEGACY_DIST_APP_DIR="$ROOT_DIR/dist/$APP_NAME"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notype-app.XXXXXX")"
APP_DIR="$STAGING_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INSTALL_DIR="/Applications/$APP_NAME"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

echo "Building NoType (Release)..."
swift build -c release --package-path "$ROOT_DIR"

echo "Building app icon..."
"$ROOT_DIR/scripts/build_icon.sh"

echo "Preparing app bundle..."
rm -rf "$LEGACY_DIST_APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/NoType" "$MACOS_DIR/NoType"
cp "$ROOT_DIR/packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/packaging/NoTypeIcon.icns" "$RESOURCES_DIR/NoTypeIcon.icns"

chmod +x "$MACOS_DIR/NoType"

echo "Applying ad-hoc signature..."
codesign --force --deep --sign - "$APP_DIR"

echo "Installing to /Applications..."
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

echo "Re-signing installed app..."
codesign --force --deep --sign - "$INSTALL_DIR"

echo "Done."
echo "Staging bundle: $APP_DIR"
echo "Installed: $INSTALL_DIR"
