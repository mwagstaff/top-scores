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

for command in jq sips; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

if ! cmp -s "$SOURCE_TEAM_MANIFEST" "$SERVER_TEAM_MANIFEST"; then
  echo "App and server team-logo manifests are out of sync" >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/top-scores-live-activity-assets.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
TEMP_OUTPUT="$TEMP_ROOT/LiveActivityGenerated"
TEMP_MANIFEST="$TEMP_ROOT/live_activity_team_logo_assets.json"
GENERATED_NAMES="$TEMP_ROOT/generated-names.txt"
mkdir -p "$TEMP_OUTPUT"

jq -n '{
  info: { author: "xcode", version: 1 },
  properties: { "provides-namespace": false }
}' > "$TEMP_OUTPUT/Contents.json"

source_filename() {
  local contents="$1"
  jq -r '
    ([.images[] | select(.filename != null and .scale == "3x")][0].filename) //
    ([.images[] | select(.filename != null)][0].filename) // empty
  ' "$contents"
}

source_asset_name() {
  # Some server-facing logo keys are aliases rather than asset-catalog names.
  # Generate a correctly named Live Activity variant from the canonical crest
  # so every key the server can send is present in the widget bundle.
  case "$1" in
    "China PR") echo "China" ;;
    "Congo DR") echo "DR Congo" ;;
    "Cote d'Ivoire") echo "Ivory Coast" ;;
    "Dominican Rep") echo "Dominican Republic" ;;
    "Hoffenheim") echo "TSG Hoffenheim" ;;
    "Levante") echo "Levante UD" ;;
    "Mainz 5") echo "1. FSVMainz 5" ;;
    "N. Ireland") echo "Northern Ireland" ;;
    "N. Macedonia") echo "North Macedonia" ;;
    "Rep. Ireland") echo "Ireland" ;;
    "United States") echo "USA" ;;
    "Verona") echo "Hellas Verona" ;;
    "VfL Wolfsberg") echo "Wolfsberger AC" ;;
    *) echo "$1" ;;
  esac
}

resize_to_fit() {
  local source="$1"
  local destination="$2"
  local max_width="$3"
  local max_height="$4"
  local dimensions width height target_width target_height

  dimensions="$(sips -g pixelWidth -g pixelHeight "$source" 2>/dev/null | awk '
    /pixelWidth:/ { width = $2 }
    /pixelHeight:/ { height = $2 }
    END { print width, height }
  ')"
  read -r width height <<< "$dimensions"

  if [[ -z "${width:-}" || -z "${height:-}" || "$width" -le 0 || "$height" -le 0 ]]; then
    echo "Could not read image dimensions: $source" >&2
    return 1
  fi

  if (( width <= max_width && height <= max_height )); then
    cp "$source" "$destination"
    return
  fi

  if (( width * max_height >= height * max_width )); then
    target_width="$max_width"
    target_height=$(( (height * max_width + width / 2) / width ))
  else
    target_height="$max_height"
    target_width=$(( (width * max_height + height / 2) / height ))
  fi

  (( target_width < 1 )) && target_width=1
  (( target_height < 1 )) && target_height=1
  sips --resampleHeightWidth "$target_height" "$target_width" "$source" --out "$destination" >/dev/null
}

generate_variant() {
  local base_name="$1"
  local max_width="$2"
  local max_height="$3"
  local source_name="${4:-$base_name}"
  local source_contents="$ASSET_CATALOG/$source_name.imageset/Contents.json"

  if [[ ! -f "$source_contents" ]]; then
    echo "Missing source asset: $base_name (resolved source: $source_name)" >&2
    return 1
  fi

  local filename source_path variant_name variant_dir output_filename
  filename="$(source_filename "$source_contents")"
  source_path="$ASSET_CATALOG/$source_name.imageset/$filename"
  if [[ -z "$filename" || ! -f "$source_path" ]]; then
    echo "Missing source image for asset: $base_name" >&2
    return 1
  fi

  variant_name="$base_name Live Activity"
  variant_dir="$TEMP_OUTPUT/$variant_name.imageset"
  # Keep the file name ASCII-only. Asset set directory names may contain
  # composed Unicode characters that APFS and actool normalize differently.
  output_filename="logo@3x.png"
  mkdir -p "$variant_dir"
  resize_to_fit "$source_path" "$variant_dir/$output_filename" "$max_width" "$max_height"

  jq -n --arg filename "$output_filename" '{
    images: [
      { idiom: "universal", scale: "1x" },
      { idiom: "universal", scale: "2x" },
      { filename: $filename, idiom: "universal", scale: "3x" }
    ],
    info: { author: "xcode", version: 1 }
  }' > "$variant_dir/Contents.json"

  printf '%s\n' "$variant_name" >> "$GENERATED_NAMES"
}

while IFS= read -r team_name; do
  generate_variant "$team_name" 36 36 "$(source_asset_name "$team_name")"
done < <(jq -r '.[]' "$SOURCE_TEAM_MANIFEST")

TV_ASSETS=(
  TVLogoAmazon
  TVLogoBBC
  TVLogoITV
  TVLogoSky
  TVLogoTNT
  TVLogoApple
  TVLogoChannel4
  TVLogoHBOMax
  TVLogoDAZN
  TVLogoDisneyPlus
  TVLogoPremierSports
  TVLogoLaLigaTV
)

for asset_name in "${TV_ASSETS[@]}"; do
  generate_variant "$asset_name" 61 33
done

generate_variant "FantasyPremierLeagueLion" 36 36

jq -R -s 'split("\n") | map(select(length > 0 and (startswith("TVLogo") | not) and . != "FantasyPremierLeagueLion Live Activity"))' \
  "$GENERATED_NAMES" > "$TEMP_MANIFEST"

if [[ "$OUTPUT_DIR" != "$ASSET_CATALOG/LiveActivityGenerated" ]]; then
  echo "Refusing to replace unexpected output directory: $OUTPUT_DIR" >&2
  exit 1
fi

rm -rf -- "$OUTPUT_DIR"
mv "$TEMP_OUTPUT" "$OUTPUT_DIR"
mv "$TEMP_MANIFEST" "$LIVE_MANIFEST"
cp "$SOURCE_TEAM_MANIFEST" "$TEAM_MANIFEST"

"$SCRIPT_DIR/verify-live-activity-assets.sh"
