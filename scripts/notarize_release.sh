#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/NoType.app"
INFO_PLIST="$ROOT_DIR/packaging/Info.plist"
VERSION="${NOTYPE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
RELEASE_DIR="$ROOT_DIR/dist/release"
ZIP_PATH="$RELEASE_DIR/NoType-${VERSION}-macOS.zip"
PROFILE="${NOTYPE_NOTARY_PROFILE:-}"

require_developer_id_signature() {
  local signature_details
  signature_details="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
  if ! printf '%s\n' "$signature_details" | grep -q "Developer ID Application:"; then
    echo "No Developer ID Application signature found on $APP_PATH" >&2
    echo "Set NOTYPE_CODESIGN_IDENTITY to your Developer ID certificate before notarizing." >&2
    exit 1
  fi
}

if [[ -z "$PROFILE" ]]; then
  echo "Missing NOTYPE_NOTARY_PROFILE." >&2
  echo "Create a keychain profile with xcrun notarytool store-credentials and export NOTYPE_NOTARY_PROFILE=<profile>." >&2
  exit 1
fi

"$ROOT_DIR/scripts/package_release.sh"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Notarization ZIP not found at $ZIP_PATH" >&2
  exit 1
fi

require_developer_id_signature

echo "Submitting $ZIP_PATH for notarization with profile $PROFILE..."
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

echo "Stapling notarization ticket to $APP_PATH..."
xcrun stapler staple "$APP_PATH"

echo "Assessing stapled app..."
codesign --verify --deep --strict "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

echo "Refreshing release artifacts from the stapled app bundle..."
NOTYPE_SKIP_BUILD=1 "$ROOT_DIR/scripts/package_release.sh"

echo "Notarized release artifacts are ready in $RELEASE_DIR"
