#!/usr/bin/env bash
set -euo pipefail

API_ROOT="${API_ROOT:-http://localhost:3011}"
ENDPOINT="${API_ROOT%/}/api/v1/admin/rogue-matches"
MODE="${MODE:-all}"

case "$MODE" in
  all)
    curl -sS \
      -X DELETE \
      "$ENDPOINT" \
      -H "Content-Type: application/json" \
      --data-binary @- <<'JSON'
{
  "delete_disallowed_competitions": true,
  "delete_live_source_duplicates": true,
  "delete_canonical_duplicates": true
}
JSON
    ;;
  disallowed)
    curl -sS \
      -X DELETE \
      "$ENDPOINT" \
      -H "Content-Type: application/json" \
      --data-binary @- <<'JSON'
{
  "delete_disallowed_competitions": true
}
JSON
    ;;
  duplicates)
    curl -sS \
      -X DELETE \
      "$ENDPOINT" \
      -H "Content-Type: application/json" \
      --data-binary @- <<'JSON'
{
  "delete_live_source_duplicates": true,
  "delete_canonical_duplicates": true
}
JSON
    ;;
  specific)
    curl -sS \
      -X DELETE \
      "$ENDPOINT" \
      -H "Content-Type: application/json" \
      --data-binary @- <<'JSON'
{
  "matches": [
    {
      "date": "2026-04-06",
      "time": "15:00",
      "league": "Championship",
      "home_team": "Blackburn Rovers",
      "away_team": "West Brom"
    },
    {
      "date": "2026-04-06",
      "time": "15:00",
      "league": "Championship",
      "home_team": "Preston North End",
      "away_team": "QPR"
    }
  ]
}
JSON
    ;;
  *)
    echo "Unsupported MODE: $MODE" >&2
    echo "Use MODE=all, MODE=disallowed, MODE=duplicates, or MODE=specific" >&2
    exit 1
    ;;
esac
