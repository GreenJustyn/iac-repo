#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v3.2 - Fixes Race Condition)
# Description: GitOps Installer for Proxmox IaC.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd)
SERVICE_NAME="proxmox-iac"

echo ">>> Starting Proxmox IaC Installation..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git

mkdir -p "$INSTALL_DIR"

# 2. Kill Stale Processes & Remove Cron
echo "--- Cleaning up old processes ---"
# Check if cron is running the script and try to comment it out
if crontab -l 2>/dev/null | grep -q "proxmox_dsc.sh"; then
    echo "WARNING: Old Cron job detected. Removing..."
    crontab -l | grep -v "proxmox_dsc.sh" | crontab -
    echo "Cron job removed."
fi

# Kill any currently running instances to clear the lock
pkill -f "proxmox_dsc.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Core Scripts
echo "--- Installing Scripts ---"

# --- Injecting the Resilient Locking Logic directly into the installed script ---
# We take the local file, but apply a sed replacement to fix the locking line
if [ -f "proxmox_dsc.sh" ]; then
    sed 's/flock -n 200/flock -w 60 200/g' proxmox_dsc.sh > "$INSTALL_DIR/proxmox_dsc.sh"
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
else
    echo "ERROR: proxmox_dsc.sh not found!"
    exit 1
fi

# Copy State
if [ -f "state.json" ]; then
    cp state.json "$INSTALL_DIR/state.json"
else
    echo "[]" > "$INSTALL_DIR/state.json"
fi

# 4. Generate Wrapper (Unchanged)
cat << 'EOF' > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
INSTALL_DIR="/root/iac"
REPO_DIR="/root/iac-repo" # Ensure this matches your git clone path
DSC_SCRIPT="$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] $1" | tee -a "$LOG_FILE"; }

# Git Auto-Update
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse @{u})

    if [ "$LOCAL" != "$REMOTE" ]; then
        log "Update detected. Pulling changes..."
        git pull
        log "Re-running setup.sh..."
        chmod +x setup.sh
        ./setup.sh
        log "Restarting wrapper..."
        exec "$0"
    fi
fi

# Dry Run
log "Starting Dry Run..."
DRY_OUTPUT=$($DSC_SCRIPT --manifest "$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=$?
FOREIGN_COUNT=$(echo "$DRY_OUTPUT" | grep -c "FOREIGN")
ERROR_COUNT=$(echo "$DRY_OUTPUT" | grep -c "ERROR")

if [ $EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed (Exit Code $EXIT_CODE). Aborting."
    echo "$DRY_OUTPUT" | tee -a "$LOG_FILE"
    exit 1
fi

if [ "$FOREIGN_COUNT" -gt 0 ]; then
    log "BLOCK: Foreign workloads detected ($FOREIGN_COUNT). Aborting."
    echo "$DRY_OUTPUT" | grep "FOREIGN" | tee -a "$LOG_FILE"
    exit 0
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    log "BLOCK: Errors detected. Aborting."
    echo "$DRY_OUTPUT" | grep "ERROR" | tee -a "$LOG_FILE"
    exit 0
fi

log "Validation Passed. Deploying..."
$DSC_SCRIPT --manifest "$STATE_FILE"
log "Workflow Complete."
EOF
chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# 5. Log Rotate & Systemd
cat <<EOF > /etc/logrotate.d/proxmox_dsc
/var/log/proxmox_dsc.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 10M
}
EOF

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Proxmox IaC GitOps Workflow
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_wrapper.sh
User=root
Nice=10
EOF

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.timer
[Unit]
Description=Run Proxmox IaC Workflow every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

# 6. Activation
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.timer

echo ">>> Installation Complete. Locking logic updated to wait-mode."
