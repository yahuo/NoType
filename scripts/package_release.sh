#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/NoType.app"
RELEASE_DIR="$ROOT_DIR/dist/release"
INFO_PLIST="$ROOT_DIR/packaging/Info.plist"
VERSION="${NOTYPE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
ARTIFACT_BASENAME="NoType-${VERSION}-macOS"
ZIP_PATH="$RELEASE_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$RELEASE_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$RELEASE_DIR/SHA256SUMS.txt"
SKIP_BUILD="${NOTYPE_SKIP_BUILD:-0}"

create_zip() {
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
}

create_dmg() {
  rm -f "$DMG_PATH"
  hdiutil create \
    -quiet \
    -volname "NoType" \
    -srcfolder "$APP_PATH" \
    -format UDZO \
    "$DMG_PATH"
}

write_checksums() {
  rm -f "$CHECKSUM_PATH"
  shasum -a 256 "$ZIP_PATH" "$DMG_PATH" > "$CHECKSUM_PATH"
}

if [[ "$SKIP_BUILD" != "1" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"

echo "Verifying app bundle signature..."
codesign --verify --deep --strict "$APP_PATH"

echo "Creating release artifacts for NoType $VERSION..."
create_zip
create_dmg
write_checksums

echo "Done."
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "SHA256: $CHECKSUM_PATH"
