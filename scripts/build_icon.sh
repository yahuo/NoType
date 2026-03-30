#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/packaging/assets/icon-concepts/notype-icon-concept.png"
ICONSET_DIR="${ICONSET_DIR:-$ROOT_DIR/packaging/AppIcon.iconset}"
OUTPUT_ICNS="${OUTPUT_ICNS:-$ROOT_DIR/packaging/NoTypeIcon.icns}"

if [[ ! -f "$SOURCE_ICON" ]]; then
  echo "Missing source icon: $SOURCE_ICON" >&2
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick 'magick' is required to build the app icon." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICNS")"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sizes=(
  "16"
  "32"
  "128"
  "256"
  "512"
)

for size in "${sizes[@]}"; do
  magick -background none "$SOURCE_ICON" -resize "${size}x${size}" "$ICONSET_DIR/icon_${size}x${size}.png"
  double_size=$((size * 2))
  magick -background none "$SOURCE_ICON" -resize "${double_size}x${double_size}" "$ICONSET_DIR/icon_${size}x${size}@2x.png"
done

rm -f "$OUTPUT_ICNS"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
echo "Built icon: $OUTPUT_ICNS"
