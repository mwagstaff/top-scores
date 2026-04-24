#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./compress-pngs.sh /path/to/your/directory
#
# Example:
#   ./compress-pngs.sh "/Users/mwagstaff/dev/top-scores/ios/Top Scores/Media.xcassets"

TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" ]]; then
  echo "❌ Please provide a directory"
  echo "Usage: $0 /path/to/directory"
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "❌ Directory does not exist: $TARGET_DIR"
  exit 1
fi

echo "🔍 Scanning: $TARGET_DIR"
echo

# 1. Remove all -small.png files
echo "🧹 Removing *-small.png files..."
find "$TARGET_DIR" -type f -iname "*-small.png" -print -delete

echo
echo "🗜 Compressing PNGs..."

# 2. Compress all PNGs (excluding already removed ones)
find "$TARGET_DIR" -type f -iname "*.png" | while IFS= read -r file; do
  orig_size=$(stat -f%z "$file")

  # Run pngquant in-place
  pngquant \
    --force \
    --skip-if-larger \
    --strip \
    --quality=80-100 \
    --ext .png \
    "$file" >/dev/null 2>&1 || true

  new_size=$(stat -f%z "$file")

  if (( new_size < orig_size )); then
    echo "✔ Compressed: $file ($orig_size → $new_size bytes)"
  else
    echo "➖ Skipped (no gain): $file"
  fi
done

echo
echo "✅ Done."