#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$SCRIPT_DIR/dashboards"

GRAFANA_URL="${GRAFANA_URL:-https://api.skynolimit.dev/grafana}"
API="$GRAFANA_URL/api"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:?GRAFANA_PASSWORD must be set}"

FOLDER_UID="${FOLDER_UID:-top-scores-folder}"
FOLDER_TITLE="${FOLDER_TITLE:-top-scores API}"
PROM_DS_NAME="${PROM_DS_NAME:-Prometheus}"
PROM_DS_UID="${PROM_DS_UID:-top-scores-prometheus}"
PROM_DS_URL="${PROM_DS_URL:-http://prometheus:9090}"

PROM_CONFIG_HOST="${PROM_CONFIG_HOST:-${DEPLOY_HOST:-}}"
PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-/etc/prometheus/prometheus.yml}"
PROM_RELOAD_URL="${PROM_RELOAD_URL:-http://localhost:9090/-/reload}"
PROM_SCRAPE_JOB_NAME="${PROM_SCRAPE_JOB_NAME:-top-scores}"
PROM_SCRAPE_TARGET="${PROM_SCRAPE_TARGET:-host.docker.internal:3011}"
PROM_SCRAPE_METRICS_PATH="${PROM_SCRAPE_METRICS_PATH:-/metrics}"

curl_json() {
  curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -H "Content-Type: application/json" "$@"
}

url_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

ensure_prometheus_datasource() {
  local response existing_id existing_type existing_uid existing_name existing_url
  local create_payload update_payload

  response="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
    "$API/datasources/uid/$(url_encode "$PROM_DS_UID")")"
  existing_id="$(jq -r '.id // empty' <<< "$response")"

  if [[ -z "$existing_id" ]]; then
    response="$(curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
      "$API/datasources/name/$(url_encode "$PROM_DS_NAME")")"
    existing_id="$(jq -r '.id // empty' <<< "$response")"
  fi

  existing_type="$(jq -r '.type // empty' <<< "$response")"
  existing_uid="$(jq -r '.uid // empty' <<< "$response")"
  existing_name="$(jq -r '.name // empty' <<< "$response")"
  existing_url="$(jq -r '.url // empty' <<< "$response")"

  if [[ -n "$existing_id" ]]; then
    if [[ "$existing_type" != "prometheus" ]]; then
      echo "Existing datasource \"$existing_name\" has type \"$existing_type\", expected prometheus." >&2
      exit 1
    fi

    if [[ -n "$existing_uid" ]]; then
      PROM_DS_UID="$existing_uid"
    fi

    if [[ "$existing_name" == "$PROM_DS_NAME" && "$existing_url" == "$PROM_DS_URL" ]]; then
      echo "Using existing Prometheus datasource \"$PROM_DS_NAME\" (uid=$PROM_DS_UID)"
      return
    fi

    update_payload="$(
      jq -cn \
        --arg name "$PROM_DS_NAME" \
        --arg uid "$PROM_DS_UID" \
        --arg url "$PROM_DS_URL" \
        '{
          name: $name,
          uid: $uid,
          type: "prometheus",
          access: "proxy",
          url: $url,
          basicAuth: false,
          jsonData: {httpMethod: "POST"}
        }'
    )"

    response="$(curl_json -X PUT "$API/datasources/uid/$(url_encode "$PROM_DS_UID")" -d "$update_payload")"
    if [[ "$(jq -r '.message // empty' <<< "$response")" != "Datasource updated" ]]; then
      echo "Failed to update Prometheus datasource: $(jq -r '.message // "unknown error"' <<< "$response")" >&2
      exit 1
    fi

    echo "Updated Prometheus datasource \"$PROM_DS_NAME\""
    return
  fi

  create_payload="$(
    jq -cn \
      --arg name "$PROM_DS_NAME" \
      --arg uid "$PROM_DS_UID" \
      --arg url "$PROM_DS_URL" \
      '{
        name: $name,
        uid: $uid,
        type: "prometheus",
        access: "proxy",
        url: $url,
        basicAuth: false,
        jsonData: {httpMethod: "POST"}
      }'
  )"

  response="$(curl_json -X POST "$API/datasources" -d "$create_payload")"
  if [[ -z "$(jq -r '.datasource.id // .id // empty' <<< "$response")" ]]; then
    echo "Failed to create Prometheus datasource: $(jq -r '.message // "unknown error"' <<< "$response")" >&2
    exit 1
  fi

  if [[ -n "$(jq -r '.datasource.uid // empty' <<< "$response")" ]]; then
    PROM_DS_UID="$(jq -r '.datasource.uid' <<< "$response")"
  fi

  echo "Created Prometheus datasource \"$PROM_DS_NAME\" (uid=$PROM_DS_UID)"
}

ensure_prometheus_scrape_config() {
  if [[ -z "$PROM_CONFIG_HOST" ]]; then
    echo "Warning: PROM_CONFIG_HOST not set, skipping Prometheus scrape config update" >&2
    return
  fi

  ssh "$PROM_CONFIG_HOST" bash -s -- \
    "$PROM_CONFIG_FILE" \
    "$PROM_SCRAPE_JOB_NAME" \
    "$PROM_SCRAPE_METRICS_PATH" \
    "$PROM_SCRAPE_TARGET" \
    "$PROM_RELOAD_URL" <<'EOF'
set -euo pipefail

config_file="$1"
job_name="$2"
metrics_path="$3"
target="$4"
reload_url="$5"

mounted_config_file="$(
  sudo docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus/prometheus.yml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
)"
if [[ -n "$mounted_config_file" ]]; then
  config_file="$mounted_config_file"
fi

begin_marker="# BEGIN ${job_name} managed scrape config"
end_marker="# END ${job_name} managed scrape config"
block="$(cat <<BLOCK
${begin_marker}
  - job_name: '${job_name}'
    metrics_path: '${metrics_path}'
    static_configs:
      - targets: ['${target}']
${end_marker}
BLOCK
)"

if [[ ! -f "$config_file" ]]; then
  sudo mkdir -p "$(dirname "$config_file")"
  cat <<'CFG' | sudo tee "$config_file" >/dev/null
global:
  scrape_interval: 15s
scrape_configs:
CFG
fi

tmp_file="$(mktemp)"
awk -v begin="$begin_marker" -v end="$end_marker" -v block="$block" '
  BEGIN {
    in_block = 0
    saw_scrape = 0
    inserted = 0
  }
  {
    if ($0 == begin) {
      in_block = 1
      next
    }
    if (in_block && $0 == end) {
      in_block = 0
      next
    }
    if (in_block) next

    if ($0 ~ /^scrape_configs:[[:space:]]*$/) {
      saw_scrape = 1
      print
      next
    }

    if (saw_scrape && !inserted && $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*$/) {
      print block
      inserted = 1
      saw_scrape = 0
    }

    print
  }
  END {
    if (saw_scrape && !inserted) {
      print block
      inserted = 1
    }
    if (!inserted) {
      print ""
      print "scrape_configs:"
      print block
    }
  }
' "$config_file" > "$tmp_file"

sudo cp "$tmp_file" "$config_file"
rm -f "$tmp_file"

http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$reload_url" || true)"
if [[ "$http_code" == "200" ]]; then
  echo "Reloaded Prometheus config"
  exit 0
fi

monitoring_dir="$(dirname "$config_file")"
compose_file="$monitoring_dir/docker-compose.yml"
if [[ -f "$compose_file" ]]; then
  if sudo docker compose -f "$compose_file" restart prometheus >/dev/null 2>&1; then
    echo "Restarted Prometheus container"
    exit 0
  fi
fi

echo "Warning: failed to reload Prometheus config automatically" >&2
EOF
}

ensure_folder() {
  local existing_uid response query

  existing_uid="$(
    curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$API/folders/$FOLDER_UID" \
      | jq -r '.uid // empty'
  )"
  if [[ "$existing_uid" == "$FOLDER_UID" ]]; then
    echo "Using existing folder uid=$FOLDER_UID"
    return
  fi

  query="$(url_encode "$FOLDER_TITLE")"
  existing_uid="$(
    curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$API/search?type=dash-folder&query=$query" \
      | jq -r --arg t "$FOLDER_TITLE" '.[] | select(.title == $t) | .uid' \
      | head -n 1
  )"
  if [[ -n "$existing_uid" ]]; then
    FOLDER_UID="$existing_uid"
    echo "Using existing folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
    return
  fi

  response="$(
    jq -cn --arg uid "$FOLDER_UID" --arg title "$FOLDER_TITLE" '{uid: $uid, title: $title}' \
      | curl_json -X POST "$API/folders" -d @-
  )"
  existing_uid="$(jq -r '.uid // empty' <<< "$response")"
  if [[ -z "$existing_uid" ]]; then
    echo "Failed to create folder \"$FOLDER_TITLE\": $(jq -r '.message // "unknown error"' <<< "$response")" >&2
    exit 1
  fi

  FOLDER_UID="$existing_uid"
  echo "Created folder \"$FOLDER_TITLE\" (uid=$FOLDER_UID)"
}

dashboard_uid_for_file() {
  local file="$1"
  local filename uid

  filename="$(basename "$file")"
  uid="$(jq -r '.uid // empty' "$file")"
  if [[ -z "$uid" ]]; then
    uid="${filename%.json}"
    uid="${uid//[^a-zA-Z0-9_-]/-}"
    uid="$(echo "$uid" | tr '[:upper:]' '[:lower:]')"
  fi
  echo "$uid"
}

inject_datasource_in_dashboard() {
  local file="$1"
  local temp_file

  temp_file="$(mktemp)"
  jq \
    --arg ds_uid "$PROM_DS_UID" \
    '
      def add_ds_if_missing:
        if type == "object" then
          (if has("targets") and ((has("datasource") | not) or .datasource == null or .datasource == "") then
             . + {datasource: {type: "prometheus", uid: $ds_uid}}
           else
             .
           end)
          | with_entries(.value |= add_ds_if_missing)
        elif type == "array" then
          map(add_ds_if_missing)
        else
          .
        end;
      add_ds_if_missing
    ' \
    "$file" > "$temp_file"

  mv "$temp_file" "$file"
}

import_dashboard_file() {
  local file="$1"
  local normalized_file uid title payload

  normalized_file="$(mktemp)"
  cp "$file" "$normalized_file"
  inject_datasource_in_dashboard "$normalized_file"

  uid="$(dashboard_uid_for_file "$file")"
  title="$(jq -r '.title' "$normalized_file")"
  echo "Importing: $title (uid=$uid)"

  payload="$(jq -c --arg folder "$FOLDER_UID" --arg uid "$uid" '
    {
      dashboard: (. + {uid: $uid, id: null}),
      folderUid: $folder,
      overwrite: true
    }' "$normalized_file")"

  rm -f "$normalized_file"
  curl_json -X POST "$API/dashboards/db" -d "$payload" | jq -r '.status // .message'
}

shopt -s nullglob
files=("$DASHBOARD_DIR"/*.json)

ensure_prometheus_scrape_config
ensure_prometheus_datasource

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No dashboards found in $DASHBOARD_DIR"
  exit 0
fi

ensure_folder

for file in "${files[@]}"; do
  import_dashboard_file "$file"
done

echo "Done."
