#!/usr/bin/env zsh
set -euo pipefail

# Deploy script for Node.js projects
# - Auto-detects entry file (prefers server.js, falls back to index.js)
# - Syncs files to remote server via rsync
# - Installs dependencies on server
# - Creates/updates launchd service for automatic startup
# - Restarts service with new code

# ---- Config ----
HOST="${DEPLOY_HOST:?DEPLOY_HOST is not set}"

# Get the directory name of this script to use as project name
SCRIPT_DIR="${0:a:h}"
PROJECT_NAME="${SCRIPT_DIR:t}"

LOCAL_DIR="$SCRIPT_DIR"
REMOTE_DIR="~/dev/${PROJECT_NAME}"

# Generate service labels based on project name
API_SERVICE_LABEL="com.${PROJECT_NAME}.api"
SCRAPER_SERVICE_LABEL="com.${PROJECT_NAME}.scraper"
MONITOR_SERVICE_LABEL="com.${PROJECT_NAME}.monitor"
AUDIT_SERVICE_LABEL="com.${PROJECT_NAME}.audit"

# Optional: if you want to deploy a specific branch/commit state, you could
# add git checks here (not included by default).
# ----------------

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "Local dir not found: $LOCAL_DIR" >&2
  exit 1
fi

echo "==> Checking if rsync is installed on remote host..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "command -v rsync >/dev/null 2>&1"; then
  echo "❌ Error: rsync is not installed on $HOST" >&2
  echo "" >&2
  echo "Please install rsync on the remote host:" >&2
  echo "  Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y rsync" >&2
  echo "  RHEL/CentOS:   sudo yum install -y rsync" >&2
  echo "  macOS:         rsync should be pre-installed" >&2
  exit 1
fi

echo "==> Ensuring remote directory exists..."
ssh "$HOST" "mkdir -p $REMOTE_DIR"

echo "==> Syncing files to ${HOST}:${REMOTE_DIR} ..."
# Notes:
# - --delete makes remote mirror local (be careful!)
# - Exclude node_modules, .git, logs, etc.
# - If you keep a production .env on the server, exclude it so it isn't overwritten.
rsync -az --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  --exclude '.DS_Store' \
  --exclude 'npm-debug.log' \
  --exclude 'yarn.lock' \
  --exclude 'pnpm-lock.yaml' \
  --exclude '.env' \
  --exclude 'coverage' \
  --exclude 'dist' \
  --exclude '.next' \
  --exclude '.turbo' \
  --exclude '*.local' \
  "$LOCAL_DIR/" \
  "${HOST}:${REMOTE_DIR}/"

echo "==> Installing deps on server..."
ssh "$HOST" "export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'; \
  cd $REMOTE_DIR && \
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  else
    npm install --omit=dev
  fi"

echo "==> Setting up and restarting services..."
ssh "$HOST" "
  set -e
  REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)
  API_ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/server.js\"
  SCRAPER_ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/scraper.js\"
  MONITOR_ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/monitor.js\"
  AUDIT_ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/audit.js\"
  API_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.log\"
  API_ERROR_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.error.log\"
  SCRAPER_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-scraper.log\"
  SCRAPER_ERROR_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-scraper.error.log\"
  MONITOR_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-monitor.log\"
  MONITOR_ERROR_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-monitor.error.log\"
  AUDIT_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-audit.log\"
  AUDIT_ERROR_LOG_FILE=\"\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}-audit.error.log\"

  if [[ ! -f \"\$API_ENTRY_FILE\" ]]; then
    echo \"Error: API entry file not found at \$API_ENTRY_FILE\" >&2
    exit 1
  fi
  if [[ ! -f \"\$SCRAPER_ENTRY_FILE\" ]]; then
    echo \"Error: scraper entry file not found at \$SCRAPER_ENTRY_FILE\" >&2
    exit 1
  fi
  if [[ ! -f \"\$MONITOR_ENTRY_FILE\" ]]; then
    echo \"Error: monitor entry file not found at \$MONITOR_ENTRY_FILE\" >&2
    exit 1
  fi
  if [[ ! -f \"\$AUDIT_ENTRY_FILE\" ]]; then
    echo \"Error: audit entry file not found at \$AUDIT_ENTRY_FILE\" >&2
    exit 1
  fi

  # Detect OS and use appropriate service manager
  if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
    echo \"==> Using launchd (macOS)\"
    DOMAIN=\"gui/\$(id -u)\"

    # Create LaunchAgent directory if it doesn't exist
    mkdir -p \"\$HOME/Library/LaunchAgents\"

    write_launchd_service() {
      local label=\"\$1\"
      local entry_file=\"\$2\"
      local log_file=\"\$3\"
      local error_log_file=\"\$4\"
      local plist=\"\$HOME/Library/LaunchAgents/\${label}.plist\"
      cat > \"\$plist\" << 'EOF_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key>
  <string>LABEL_PLACEHOLDER</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/node</string>
    <string>ENTRY_FILE_PLACEHOLDER</string>
  </array>
  <key>WorkingDirectory</key>
  <string>REMOTE_DIR_PLACEHOLDER</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>LOG_FILE_PLACEHOLDER</string>
  <key>StandardErrorPath</key>
  <string>ERROR_LOG_FILE_PLACEHOLDER</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF_PLIST
      sed -i '' \"s|LABEL_PLACEHOLDER|\$label|g\" \"\$plist\"
      sed -i '' \"s|ENTRY_FILE_PLACEHOLDER|\$entry_file|g\" \"\$plist\"
      sed -i '' \"s|REMOTE_DIR_PLACEHOLDER|\$REMOTE_DIR_EXPANDED|g\" \"\$plist\"
      sed -i '' \"s|LOG_FILE_PLACEHOLDER|\$log_file|g\" \"\$plist\"
      sed -i '' \"s|ERROR_LOG_FILE_PLACEHOLDER|\$error_log_file|g\" \"\$plist\"
    }

    restart_launchd_service() {
      local label=\"\$1\"
      local plist=\"\$HOME/Library/LaunchAgents/\${label}.plist\"
      launchctl bootout \"\$DOMAIN/\$label\" 2>/dev/null || true
      launchctl bootstrap \"\$DOMAIN\" \"\$plist\"
      launchctl enable \"\$DOMAIN/\$label\" || true
      launchctl kickstart -k \"\$DOMAIN/\$label\"
    }

    write_launchd_service \"${SCRAPER_SERVICE_LABEL}\" \"\$SCRAPER_ENTRY_FILE\" \"\$SCRAPER_LOG_FILE\" \"\$SCRAPER_ERROR_LOG_FILE\"
    restart_launchd_service \"${SCRAPER_SERVICE_LABEL}\"
    echo 'Scraper service restarted via launchd'

    write_launchd_service \"${API_SERVICE_LABEL}\" \"\$API_ENTRY_FILE\" \"\$API_LOG_FILE\" \"\$API_ERROR_LOG_FILE\"
    restart_launchd_service \"${API_SERVICE_LABEL}\"
    echo 'API service restarted via launchd'

    write_launchd_service \"${MONITOR_SERVICE_LABEL}\" \"\$MONITOR_ENTRY_FILE\" \"\$MONITOR_LOG_FILE\" \"\$MONITOR_ERROR_LOG_FILE\"
    restart_launchd_service \"${MONITOR_SERVICE_LABEL}\"
    echo 'Monitor service restarted via launchd'

    write_launchd_service \"${AUDIT_SERVICE_LABEL}\" \"\$AUDIT_ENTRY_FILE\" \"\$AUDIT_LOG_FILE\" \"\$AUDIT_ERROR_LOG_FILE\"
    restart_launchd_service \"${AUDIT_SERVICE_LABEL}\"
    echo 'Audit service restarted via launchd'

  elif command -v systemctl >/dev/null 2>&1; then
    echo \"==> Using systemd (Linux)\"

    # Create systemd user directory
    mkdir -p \"\$HOME/.config/systemd/user\"

    write_systemd_service() {
      local label=\"\$1\"
      local entry_file=\"\$2\"
      local log_file=\"\$3\"
      local error_log_file=\"\$4\"
      local description=\"\$5\"
      local service_file=\"\$HOME/.config/systemd/user/\${label}.service\"
      cat > \"\$service_file\" << EOF_SYSTEMD
[Unit]
Description=\${description}
After=network.target

[Service]
Type=simple
WorkingDirectory=\$REMOTE_DIR_EXPANDED
ExecStart=\$(command -v node) \$entry_file
Restart=always
RestartSec=10
StandardOutput=append:\$log_file
StandardError=append:\$error_log_file
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF_SYSTEMD
    }

    restart_systemd_service() {
      local label=\"\$1\"
      systemctl --user enable \"\${label}.service\"
      systemctl --user restart \"\${label}.service\"
      systemctl --user status \"\${label}.service\" --no-pager || true
    }

    write_systemd_service \"${SCRAPER_SERVICE_LABEL}\" \"\$SCRAPER_ENTRY_FILE\" \"\$SCRAPER_LOG_FILE\" \"\$SCRAPER_ERROR_LOG_FILE\" \"${PROJECT_NAME} Scraper Service\"
    write_systemd_service \"${API_SERVICE_LABEL}\" \"\$API_ENTRY_FILE\" \"\$API_LOG_FILE\" \"\$API_ERROR_LOG_FILE\" \"${PROJECT_NAME} API Service\"
    write_systemd_service \"${MONITOR_SERVICE_LABEL}\" \"\$MONITOR_ENTRY_FILE\" \"\$MONITOR_LOG_FILE\" \"\$MONITOR_ERROR_LOG_FILE\" \"${PROJECT_NAME} Monitor Service\"
    write_systemd_service \"${AUDIT_SERVICE_LABEL}\" \"\$AUDIT_ENTRY_FILE\" \"\$AUDIT_LOG_FILE\" \"\$AUDIT_ERROR_LOG_FILE\" \"${PROJECT_NAME} Audit Service\"

    systemctl --user daemon-reload
    restart_systemd_service \"${SCRAPER_SERVICE_LABEL}\"
    echo 'Scraper service restarted via systemd'
    restart_systemd_service \"${API_SERVICE_LABEL}\"
    echo 'API service restarted via systemd'
    restart_systemd_service \"${MONITOR_SERVICE_LABEL}\"
    echo 'Monitor service restarted via systemd'
    restart_systemd_service \"${AUDIT_SERVICE_LABEL}\"
    echo 'Audit service restarted via systemd'

  else
    echo \"Error: Neither launchd nor systemd found. Cannot manage service.\" >&2
    exit 1
  fi
"

# Check for and run Grafana dashboard import script if it exists
DASHBOARD_SCRIPT="$LOCAL_DIR/observability/grafana/import-dashboards.sh"
if [[ -f "$DASHBOARD_SCRIPT" ]]; then
  echo "==> Running Grafana dashboard import script..."
  REMOTE_HOME="$(ssh "$HOST" "printf %s \"\$HOME\"")"

  # Prefer the actual mounted Prometheus config file path from the running container.
  AUTO_PROM_CONFIG_FILE="$(
    ssh "$HOST" "sudo docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination \"/etc/prometheus/prometheus.yml\"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true"
  )"
  if [[ -z "$AUTO_PROM_CONFIG_FILE" ]]; then
    AUTO_PROM_CONFIG_FILE="${REMOTE_HOME}/monitoring/prometheus.yml"
  fi

  # Prefer host primary IPv4 for scraping host services from containers.
  AUTO_PROM_HOST_IP="$(
    ssh "$HOST" "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if (\$i==\"src\") {print \$(i+1); exit}}' || true"
  )"
  if [[ -z "$AUTO_PROM_HOST_IP" ]]; then
    AUTO_PROM_HOST_IP="$(
      ssh "$HOST" "hostname -I 2>/dev/null | awk '{print \$1}' || true"
    )"
  fi

  # Also detect Docker gateway as a fallback.
  AUTO_PROM_GW="$(
    ssh "$HOST" "sudo docker inspect prometheus --format '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' 2>/dev/null | awk '{print \$1}' || true"
  )"

  if [[ -n "$AUTO_PROM_HOST_IP" ]]; then
    AUTO_PROM_SCRAPE_HOST="$AUTO_PROM_HOST_IP"
  elif [[ -n "$AUTO_PROM_GW" ]]; then
    AUTO_PROM_SCRAPE_HOST="$AUTO_PROM_GW"
  else
    AUTO_PROM_SCRAPE_HOST="host.docker.internal"
  fi

  AUTO_PROM_SCRAPE_TARGETS="${AUTO_PROM_SCRAPE_HOST}:3010,${AUTO_PROM_SCRAPE_HOST}:3015"

  echo "   Prometheus config: ${AUTO_PROM_CONFIG_FILE}"
  echo "   Host IP candidate: ${AUTO_PROM_HOST_IP:-<none>}"
  echo "   Docker GW fallback: ${AUTO_PROM_GW:-<none>}"
  echo "   Prometheus scrape targets: ${AUTO_PROM_SCRAPE_TARGETS}"

  AUTO_PROM_NET_NAME="$(
    ssh "$HOST" "sudo docker inspect prometheus --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' 2>/dev/null | awk '{print \$1}' || true"
  )"
  AUTO_PROM_SUBNET=""
  if [[ -n "$AUTO_PROM_NET_NAME" ]]; then
    AUTO_PROM_SUBNET="$(
      ssh "$HOST" "sudo docker network inspect \"$AUTO_PROM_NET_NAME\" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true"
    )"
  fi
  if [[ -n "$AUTO_PROM_SUBNET" ]]; then
    for AUTO_PROM_SCRAPE_PORT in 3010 3015; do
      echo "   Ensuring firewall allows ${AUTO_PROM_SUBNET} -> tcp/${AUTO_PROM_SCRAPE_PORT}"
      ssh "$HOST" "sudo iptables -C INPUT -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT"
    done
  fi

  PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-${AUTO_PROM_CONFIG_FILE}}" \
  PROM_SCRAPE_TARGETS="${PROM_SCRAPE_TARGETS:-${AUTO_PROM_SCRAPE_TARGETS}}" \
    "$DASHBOARD_SCRIPT"
else
  echo "==> No Grafana dashboard import script found, skipping..."
fi

echo "✅ Deploy complete."
