#!/usr/bin/env bash
set -euo pipefail

API_ROOT="${API_ROOT:-http://localhost:3011}"
ENDPOINT="${API_ROOT%/}/api/v1/admin/rogue-matches"

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

