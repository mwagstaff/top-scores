#!/usr/bin/env bash
set -euo pipefail

BASE_URL_LOCAL_DEFAULT="http://localhost:3011/api/v1"
BASE_URL_PROD_DEFAULT="https://api.skynolimit.dev/top-scores/api/v1"

usage() {
  cat <<'EOF'
Usage:
  live_activity_test_harness.sh state  <USER_DEVICE_TOKEN> [BASE_URL|prod|local]
  live_activity_test_harness.sh start  <USER_DEVICE_TOKEN> [BASE_URL|prod|local] [MODE] [FORCE_START] [FALLBACK_START_ON_UPDATE_FAILURE] [TEST_HOLD_SECONDS]
  live_activity_test_harness.sh update <USER_DEVICE_TOKEN> [BASE_URL|prod|local] [MODE]
  live_activity_test_harness.sh end    <USER_DEVICE_TOKEN> [BASE_URL|prod|local]

Examples:
  ./live_activity_test_harness.sh state  2F4A...
  ./live_activity_test_harness.sh start  2F4A... http://localhost:3011/api/v1 single_live
  ./live_activity_test_harness.sh start  2F4A... prod single_live
  ./live_activity_test_harness.sh start  2F4A... prod single_live true
  ./live_activity_test_harness.sh start  2F4A... prod single_live false true
  ./live_activity_test_harness.sh start  2F4A... prod single_live false false 600
  ./live_activity_test_harness.sh update 2F4A... http://localhost:3011/api/v1 single_live
  ./live_activity_test_harness.sh end    2F4A...
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

ACTION="$1"
USER_DEVICE_TOKEN="$2"
BASE_URL_INPUT="${3:-local}"
MODE="${4:-single_live}"
FORCE_START_RAW="${5:-false}"
FALLBACK_START_ON_UPDATE_FAILURE_RAW="${6:-false}"
TEST_HOLD_SECONDS_RAW="${7:-300}"
FORCE_START_LOWER="$(printf '%s' "$FORCE_START_RAW" | tr '[:upper:]' '[:lower:]')"
FALLBACK_START_ON_UPDATE_FAILURE_LOWER="$(printf '%s' "$FALLBACK_START_ON_UPDATE_FAILURE_RAW" | tr '[:upper:]' '[:lower:]')"
FORCE_START_JSON=false
FALLBACK_START_ON_UPDATE_FAILURE_JSON=false
if [[ "$FORCE_START_LOWER" == "true" || "$FORCE_START_LOWER" == "1" || "$FORCE_START_LOWER" == "yes" ]]; then
  FORCE_START_JSON=true
fi
if [[ "$FALLBACK_START_ON_UPDATE_FAILURE_LOWER" == "true" || "$FALLBACK_START_ON_UPDATE_FAILURE_LOWER" == "1" || "$FALLBACK_START_ON_UPDATE_FAILURE_LOWER" == "yes" ]]; then
  FALLBACK_START_ON_UPDATE_FAILURE_JSON=true
fi
if [[ "$TEST_HOLD_SECONDS_RAW" =~ ^[0-9]+$ ]]; then
  TEST_HOLD_SECONDS_JSON="$TEST_HOLD_SECONDS_RAW"
else
  TEST_HOLD_SECONDS_JSON=300
fi

BASE_URL_INPUT_LOWER="$(printf '%s' "$BASE_URL_INPUT" | tr '[:upper:]' '[:lower:]')"
TODAY="$(date +%Y-%m-%d)"

case "$BASE_URL_INPUT_LOWER" in
  prod|production)
    BASE_URL="$BASE_URL_PROD_DEFAULT"
    ;;
  local|localhost)
    BASE_URL="$BASE_URL_LOCAL_DEFAULT"
    ;;
  *)
    BASE_URL="$BASE_URL_INPUT"
    ;;
esac

curl_json() {
  local method="$1"
  local url="$2"
  local json="${3:-}"
  if [[ -n "$json" ]]; then
    curl -sS -X "$method" \
      "$url" \
      -H "Content-Type: application/json" \
      -H "X-Device-Token: $USER_DEVICE_TOKEN" \
      -d "$json"
  else
    curl -sS -X "$method" \
      "$url" \
      -H "Content-Type: application/json" \
      -H "X-Device-Token: $USER_DEVICE_TOKEN"
  fi
  echo
}

multi_live_matches_json() {
  cat <<EOF
[
  {
    "matchId": "test_multi_live_1",
    "date": "$TODAY",
    "time": "19:45",
    "league": "UEFA Champions League",
    "leagueSubcategory": "Round of 16",
    "homeTeam": "Atalanta",
    "awayTeam": "Borussia Dortmund",
    "homeScore": 2,
    "awayScore": 0,
    "aggregateHomeScore": 4,
    "aggregateAwayScore": 2,
    "matchTime": "45+2'",
    "tvChannels": ["TNT Sports 1"]
  },
  {
    "matchId": "test_multi_live_2",
    "date": "$TODAY",
    "time": "20:00",
    "league": "Premier League",
    "homeTeam": "Norwich City",
    "awayTeam": "Sheffield Wednesday",
    "homeScore": 1,
    "awayScore": 1,
    "matchTime": "55'",
    "tvChannels": ["Sky Sports Main Event"]
  },
  {
    "matchId": "test_multi_live_3",
    "date": "$TODAY",
    "time": "20:00",
    "league": "UEFA Champions League",
    "leagueSubcategory": "Round of 16",
    "homeTeam": "Inter Milan",
    "awayTeam": "Benfica",
    "homeScore": 2,
    "awayScore": 1,
    "aggregateHomeScore": 3,
    "aggregateAwayScore": 3,
    "matchTime": "110'",
    "tvChannels": ["TNT Sports 1"]
  },
  {
    "matchId": "test_multi_live_4",
    "date": "$TODAY",
    "time": "20:00",
    "league": "Premier League",
    "homeTeam": "Arsenal",
    "awayTeam": "Chelsea",
    "homeScore": 3,
    "awayScore": 2,
    "matchTime": "78'",
    "tvChannels": ["Sky Sports Main Event"]
  },
  {
    "matchId": "test_multi_live_5",
    "date": "$TODAY",
    "time": "20:15",
    "league": "UEFA Europa League",
    "homeTeam": "Roma",
    "awayTeam": "Leverkusen",
    "homeScore": 1,
    "awayScore": 1,
    "matchTime": "67'",
    "tvChannels": ["TNT Sports 1"]
  },
  {
    "matchId": "test_multi_live_6",
    "date": "$TODAY",
    "time": "20:15",
    "league": "FA Cup",
    "homeTeam": "Liverpool",
    "awayTeam": "Everton",
    "homeScore": 0,
    "awayScore": 1,
    "matchTime": "52'",
    "tvChannels": ["ITV1"]
  },
  {
    "matchId": "test_multi_live_7",
    "date": "$TODAY",
    "time": "20:30",
    "league": "UEFA Conference League",
    "homeTeam": "Fiorentina",
    "awayTeam": "Lille",
    "homeScore": 1,
    "awayScore": 0,
    "matchTime": "61'",
    "tvChannels": ["TNT Sports 2"]
  },
  {
    "matchId": "test_multi_live_8",
    "date": "$TODAY",
    "time": "20:30",
    "league": "EFL Cup",
    "homeTeam": "Newcastle United",
    "awayTeam": "Man City",
    "homeScore": 2,
    "awayScore": 2,
    "matchTime": "84'",
    "tvChannels": ["Sky Sports Football"]
  },
  {
    "matchId": "test_multi_live_9",
    "date": "$TODAY",
    "time": "20:45",
    "league": "Premier League",
    "homeTeam": "Spurs",
    "awayTeam": "West Ham",
    "homeScore": 1,
    "awayScore": 1,
    "matchTime": "73'",
    "tvChannels": ["Sky Sports Premier League"]
  },
  {
    "matchId": "test_multi_live_10",
    "date": "$TODAY",
    "time": "20:45",
    "league": "UEFA Champions League",
    "homeTeam": "Real Madrid",
    "awayTeam": "Bayern Munich",
    "homeScore": 0,
    "awayScore": 0,
    "matchTime": "33'",
    "tvChannels": ["TNT Sports 1"]
  }
]
EOF
}

case "$ACTION" in
  state)
    curl_json GET "$BASE_URL/live-activity/test/state"
    ;;
  start)
    if [[ "$MODE" == "multi_live" ]]; then
      MATCHES_JSON="$(multi_live_matches_json)"
      curl_json POST "$BASE_URL/live-activity/test/start" "{
        \"userDeviceToken\": \"$USER_DEVICE_TOKEN\",
        \"mode\": \"$MODE\",
        \"delayMinutes\": 5,
        \"matches\": $MATCHES_JSON,
        \"forceStart\": $FORCE_START_JSON,
        \"fallbackStartOnUpdateFailure\": $FALLBACK_START_ON_UPDATE_FAILURE_JSON,
        \"testHoldSeconds\": $TEST_HOLD_SECONDS_JSON,
        \"title\": \"Top Scores Test\",
        \"body\": \"Live Activity start test from CLI\"
      }"
    else
      curl_json POST "$BASE_URL/live-activity/test/start" "{
        \"userDeviceToken\": \"$USER_DEVICE_TOKEN\",
        \"mode\": \"$MODE\",
        \"delayMinutes\": 5,
        \"forceStart\": $FORCE_START_JSON,
        \"fallbackStartOnUpdateFailure\": $FALLBACK_START_ON_UPDATE_FAILURE_JSON,
        \"testHoldSeconds\": $TEST_HOLD_SECONDS_JSON,
        \"title\": \"Top Scores Test\",
        \"body\": \"Live Activity start test from CLI\"
      }"
    fi
    ;;
  update)
    if [[ "$MODE" == "multi_live" ]]; then
      MATCHES_JSON="$(multi_live_matches_json)"
      curl_json POST "$BASE_URL/live-activity/test/update" "{
        \"userDeviceToken\": \"$USER_DEVICE_TOKEN\",
        \"mode\": \"$MODE\",
        \"delayMinutes\": 5,
        \"matches\": $MATCHES_JSON
      }"
    else
      curl_json POST "$BASE_URL/live-activity/test/update" "{
        \"userDeviceToken\": \"$USER_DEVICE_TOKEN\",
        \"mode\": \"$MODE\",
        \"delayMinutes\": 5,
        \"matches\": [
          {
            \"matchId\": \"test_live_1\",
            \"date\": \"$(date +%Y-%m-%d)\",
            \"time\": \"$(date +%H:%M)\",
            \"league\": \"UEFA Champions League\",
            \"homeTeam\": \"Atalanta\",
            \"awayTeam\": \"Borussia Dortmund\",
            \"homeScore\": 2,
            \"awayScore\": 0,
            \"matchTime\": \"45+2'\",
            \"tvChannels\": [\"TNT Sports 1\"]
          }
        ]
      }"
    fi
    ;;
  end)
    curl_json POST "$BASE_URL/live-activity/test/end" "{
      \"userDeviceToken\": \"$USER_DEVICE_TOKEN\"
    }"
    ;;
  *)
    usage
    exit 1
    ;;
esac
