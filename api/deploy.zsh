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

# Generate service label based on project name
SERVICE_LABEL="com.${PROJECT_NAME}.api"

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

echo "==> Setting up and restarting service..."
ssh "$HOST" "
  set -e
  REMOTE_DIR_EXPANDED=\$(eval echo $REMOTE_DIR)

  # Detect which entry file to use (server.js or index.js)
  if [[ -f \"\$REMOTE_DIR_EXPANDED/server.js\" ]]; then
    ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/server.js\"
    echo 'Using server.js as entry point'
  elif [[ -f \"\$REMOTE_DIR_EXPANDED/index.js\" ]]; then
    ENTRY_FILE=\"\$REMOTE_DIR_EXPANDED/index.js\"
    echo 'Using index.js as entry point'
  else
    echo \"Error: Neither server.js nor index.js found in \$REMOTE_DIR_EXPANDED\" >&2
    exit 1
  fi

  # Detect OS and use appropriate service manager
  if [[ \"\$OSTYPE\" == \"darwin\"* ]] || command -v launchctl >/dev/null 2>&1; then
    echo \"==> Using launchd (macOS)\"
    PLIST=\"\$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist\"
    DOMAIN=\"gui/\$(id -u)\"

    # Create LaunchAgent directory if it doesn't exist
    mkdir -p \"\$HOME/Library/LaunchAgents\"

    # Create plist file
    cat > \"\$PLIST\" << 'EOF_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>
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
  <string>REMOTE_DIR_PLACEHOLDER/${PROJECT_NAME}.log</string>
  <key>StandardErrorPath</key>
  <string>REMOTE_DIR_PLACEHOLDER/${PROJECT_NAME}.error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF_PLIST

    # Replace placeholders
    sed -i '' \"s|ENTRY_FILE_PLACEHOLDER|\$ENTRY_FILE|g\" \"\$PLIST\"
    sed -i '' \"s|REMOTE_DIR_PLACEHOLDER|\$REMOTE_DIR_EXPANDED|g\" \"\$PLIST\"

    # Restart service
    launchctl bootout \"\$DOMAIN/$SERVICE_LABEL\" 2>/dev/null || true
    launchctl bootstrap \"\$DOMAIN\" \"\$PLIST\"
    launchctl enable \"\$DOMAIN/$SERVICE_LABEL\" || true
    launchctl kickstart -k \"\$DOMAIN/$SERVICE_LABEL\"
    echo 'Service restarted via launchd'

  elif command -v systemctl >/dev/null 2>&1; then
    echo \"==> Using systemd (Linux)\"
    SERVICE_FILE=\"\$HOME/.config/systemd/user/${SERVICE_LABEL}.service\"

    # Create systemd user directory
    mkdir -p \"\$HOME/.config/systemd/user\"

    # Create systemd service file
    cat > \"\$SERVICE_FILE\" << EOF_SYSTEMD
[Unit]
Description=${PROJECT_NAME} API Service
After=network.target

[Service]
Type=simple
WorkingDirectory=\$REMOTE_DIR_EXPANDED
ExecStart=\$(command -v node) \$ENTRY_FILE
Restart=always
RestartSec=10
StandardOutput=append:\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.log
StandardError=append:\$REMOTE_DIR_EXPANDED/${PROJECT_NAME}.error.log
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF_SYSTEMD

    # Reload systemd, enable and restart service
    systemctl --user daemon-reload
    systemctl --user enable ${SERVICE_LABEL}.service
    systemctl --user restart ${SERVICE_LABEL}.service
    echo 'Service restarted via systemd'

    # Show service status
    systemctl --user status ${SERVICE_LABEL}.service --no-pager || true

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
    AUTO_PROM_SCRAPE_TARGET="${AUTO_PROM_HOST_IP}:3010"
  elif [[ -n "$AUTO_PROM_GW" ]]; then
    AUTO_PROM_SCRAPE_TARGET="${AUTO_PROM_GW}:3010"
  else
    AUTO_PROM_SCRAPE_TARGET="host.docker.internal:3010"
  fi

  echo "   Prometheus config: ${AUTO_PROM_CONFIG_FILE}"
  echo "   Host IP candidate: ${AUTO_PROM_HOST_IP:-<none>}"
  echo "   Docker GW fallback: ${AUTO_PROM_GW:-<none>}"
  echo "   Prometheus scrape target: ${AUTO_PROM_SCRAPE_TARGET}"

  AUTO_PROM_SCRAPE_PORT="${AUTO_PROM_SCRAPE_TARGET##*:}"
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
    echo "   Ensuring firewall allows ${AUTO_PROM_SUBNET} -> tcp/${AUTO_PROM_SCRAPE_PORT}"
    ssh "$HOST" "sudo iptables -C INPUT -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -p tcp -s \"$AUTO_PROM_SUBNET\" --dport \"$AUTO_PROM_SCRAPE_PORT\" -j ACCEPT"
  fi

  PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-${AUTO_PROM_CONFIG_FILE}}" \
  PROM_SCRAPE_TARGET="${PROM_SCRAPE_TARGET:-${AUTO_PROM_SCRAPE_TARGET}}" \
    "$DASHBOARD_SCRIPT"
else
  echo "==> No Grafana dashboard import script found, skipping..."
fi

echo "✅ Deploy complete."
