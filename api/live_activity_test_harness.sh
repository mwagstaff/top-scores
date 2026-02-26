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

case "$ACTION" in
  state)
    curl_json GET "$BASE_URL/live-activity/test/state"
    ;;
  start)
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
    ;;
  update)
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
