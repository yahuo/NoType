#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
APP_NAME="NoType.app"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP_DIR="$DIST_DIR/$APP_NAME"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notype-app.XXXXXX")"
ICON_BUILD_DIR="$STAGING_DIR/icon-build"
APP_DIR="$STAGING_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ICON_BUILD_DIR/AppIcon.iconset"
OUTPUT_ICNS="$ICON_BUILD_DIR/NoTypeIcon.icns"

cleanup() {
  rm -rf "$STAGING_DIR"
}

select_codesign_identity() {
  if [[ -n "${NOTYPE_CODESIGN_IDENTITY:-}" ]]; then
    echo "$NOTYPE_CODESIGN_IDENTITY"
    return
  fi

  local identity_output
  identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  local developer_id
  developer_id="$(printf '%s\n' "$identity_output" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
  if [[ -n "$developer_id" ]]; then
    echo "$developer_id"
    return
  fi

  local apple_development
  apple_development="$(printf '%s\n' "$identity_output" | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
  if [[ -n "$apple_development" ]]; then
    echo "$apple_development"
    return
  fi

  echo "-"
}

trap cleanup EXIT

echo "Building NoType (Release)..."
swift build -c release --package-path "$ROOT_DIR"

echo "Building app icon..."
ICONSET_DIR="$ICONSET_DIR" OUTPUT_ICNS="$OUTPUT_ICNS" "$ROOT_DIR/scripts/build_icon.sh"

echo "Preparing app bundle..."
rm -rf "$DIST_APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$DIST_DIR"

cp "$BUILD_DIR/NoType" "$MACOS_DIR/NoType"
cp "$ROOT_DIR/packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$OUTPUT_ICNS" "$RESOURCES_DIR/NoTypeIcon.icns"

chmod +x "$MACOS_DIR/NoType"

SIGN_IDENTITY="$(select_codesign_identity)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "No signing certificate found. Falling back to ad-hoc signature..."
else
  echo "Applying signature with identity: $SIGN_IDENTITY"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"

echo "Copying signed bundle to dist/..."
rm -rf "$DIST_APP_DIR"
ditto "$APP_DIR" "$DIST_APP_DIR"

if [[ ! -d "$DIST_APP_DIR" ]]; then
  echo "Failed to copy signed bundle to $DIST_APP_DIR" >&2
  exit 1
fi

echo "Done."
echo "Bundle: $DIST_APP_DIR"
