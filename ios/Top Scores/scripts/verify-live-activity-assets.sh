#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSET_CATALOG="$PROJECT_DIR/Media.xcassets"
SOURCE_TEAM_MANIFEST="$PROJECT_DIR/Top Scores/team_logo_assets.json"
SERVER_TEAM_MANIFEST="$PROJECT_DIR/../../api/team_logo_assets.json"
TEAM_MANIFEST="$PROJECT_DIR/Top Scores Widgets/team_logo_assets.json"
LIVE_MANIFEST="$PROJECT_DIR/Top Scores Widgets/live_activity_team_logo_assets.json"
OUTPUT_DIR="$ASSET_CATALOG/LiveActivityGenerated"
failures=0

if ! cmp -s "$SOURCE_TEAM_MANIFEST" "$SERVER_TEAM_MANIFEST"; then
  echo "App and server team-logo manifests are out of sync" >&2
  failures=$((failures + 1))
fi

if ! cmp -s "$SOURCE_TEAM_MANIFEST" "$TEAM_MANIFEST"; then
  echo "Widget team-logo manifest is out of sync with the app manifest" >&2
  failures=$((failures + 1))
fi

check_variant() {
  local variant_name="$1"
  local max_width="$2"
  local max_height="$3"
  local variant_dir="$OUTPUT_DIR/$variant_name.imageset"
  local contents="$variant_dir/Contents.json"

  if [[ ! -f "$contents" ]]; then
    echo "Missing Live Activity asset: $variant_name" >&2
    failures=$((failures + 1))
    return
  fi

  local filename image_path dimensions width height scale
  filename="$(jq -r '[.images[] | select(.filename != null)][0].filename // empty' "$contents")"
  scale="$(jq -r '[.images[] | select(.filename != null)][0].scale // empty' "$contents")"
  image_path="$variant_dir/$filename"
  if [[ "$scale" != "3x" || -z "$filename" || ! -f "$image_path" ]]; then
    echo "Invalid 3x Live Activity asset: $variant_name" >&2
    failures=$((failures + 1))
    return
  fi

  dimensions="$(sips -g pixelWidth -g pixelHeight "$image_path" 2>/dev/null | awk '
    /pixelWidth:/ { width = $2 }
    /pixelHeight:/ { height = $2 }
    END { print width, height }
  ')"
  read -r width height <<< "$dimensions"
  if [[ -z "${width:-}" || -z "${height:-}" || "$width" -gt "$max_width" || "$height" -gt "$max_height" ]]; then
    echo "Oversized Live Activity asset: $variant_name (${width:-?}x${height:-?}, max ${max_width}x${max_height})" >&2
    failures=$((failures + 1))
  fi
}

if [[ ! -f "$LIVE_MANIFEST" ]]; then
  echo "Missing Live Activity team-logo manifest" >&2
  exit 1
fi

expected_team_count=0
while IFS= read -r team_name; do
  variant_name="$team_name Live Activity"
  expected_team_count=$((expected_team_count + 1))
  if ! jq -e --arg name "$variant_name" 'index($name) != null' "$LIVE_MANIFEST" >/dev/null; then
    echo "Live Activity manifest is missing: $variant_name" >&2
    failures=$((failures + 1))
  fi
  check_variant "$variant_name" 36 36
done < <(jq -r '.[]' "$SOURCE_TEAM_MANIFEST")

actual_team_count="$(jq 'length' "$LIVE_MANIFEST")"
if [[ "$actual_team_count" -ne "$expected_team_count" ]]; then
  echo "Live Activity manifest count mismatch: expected $expected_team_count, found $actual_team_count" >&2
  failures=$((failures + 1))
fi

for asset_name in \
  TVLogoAmazon TVLogoBBC TVLogoITV TVLogoSky TVLogoTNT TVLogoApple \
  TVLogoChannel4 TVLogoHBOMax TVLogoDAZN TVLogoDisneyPlus \
  TVLogoPremierSports TVLogoLaLigaTV; do
  check_variant "$asset_name Live Activity" 61 33
done

check_variant "FantasyPremierLeagueLion Live Activity" 36 36

if [[ "$failures" -ne 0 ]]; then
  echo "Live Activity asset verification failed with $failures issue(s)." >&2
  exit 1
fi

echo "Verified $actual_team_count team logos, 12 TV logos, and the fantasy icon for Live Activity presentation limits."
