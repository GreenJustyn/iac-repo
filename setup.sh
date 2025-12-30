#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh
# Description: GitOps Installer for Proxmox IaC. 
#              Installs dependencies, scripts, configs, and systemd units.
#              Designed to be re-runnable for updates.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd) # Assumes setup.sh is run from inside the git repo
SERVICE_NAME="proxmox-iac"

echo ">>> Starting Proxmox IaC Installation..."

# 1. Dependency Check
echo "--- Checking Dependencies ---"
apt-get update -qq
command -v jq >/dev/null 2>&1 || { echo "Installing jq..."; apt-get install -y jq; }
command -v git >/dev/null 2>&1 || { echo "Installing git..."; apt-get install -y git; }

# 2. Directory Setup
mkdir -p "$INSTALL_DIR"

# 3. Install Core Scripts
# We copy from the current repo location to the install location
# allowing the repo to live anywhere (e.g., /root/git/my-repo)

echo "--- Installing Scripts ---"

# Copy the DSC Logic (The v3.1 script we built)
if [ -f "proxmox_dsc.sh" ]; then
    cp proxmox_dsc.sh "$INSTALL_DIR/proxmox_dsc.sh"
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
else
    echo "ERROR: proxmox_dsc.sh not found in current directory!"
    exit 1
fi

# Copy the State File (If strictly managed by git, always overwrite. 
# If local changes allowed, check existence. Assuming Git is source of truth: Overwrite)
if [ -f "state.json" ]; then
    cp state.json "$INSTALL_DIR/state.json"
else
    echo "WARNING: state.json not found. Creating empty template."
    echo "[]" > "$INSTALL_DIR/state.json"
fi

# 4. Generate the "Wrapper" Script (The Brain of the Workflow)
# This script handles the Git Update -> Dry Run -> Deploy logic
cat << 'EOF' > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
# Wrapper script executed by Systemd Timer
# Handles Git Auto-Update, Safety Checks, and Deployment

INSTALL_DIR="/root/iac"
REPO_DIR="/root/iac-repo" # UPDATE THIS to match your actual git clone path
DSC_SCRIPT="$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] $1" | tee -a "$LOG_FILE"; }

# --- Step 1: Git Update Check ---
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    log "Checking for git updates..."
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse @{u})

    if [ "$LOCAL" != "$REMOTE" ]; then
        log "Update detected. Pulling changes..."
        git pull
        log "Re-running setup.sh to apply updates..."
        chmod +x setup.sh
        ./setup.sh
        log "Update complete. Restarting wrapper process..."
        exec "$0" # Restart this script to use new code
    fi
else
    log "WARN: No git repo found at $REPO_DIR. Skipping auto-update."
fi

# --- Step 2: Dry Run & Validation ---
log "Starting Dry Run..."
DRY_OUTPUT=$($DSC_SCRIPT --manifest "$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=$?

# Capture Critical Issues
FOREIGN_COUNT=$(echo "$DRY_OUTPUT" | grep -c "FOREIGN")
ERROR_COUNT=$(echo "$DRY_OUTPUT" | grep -c "ERROR")

# --- Step 3: Decision Logic ---
if [ $EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed (Exit Code $EXIT_CODE). Aborting."
    echo "$DRY_OUTPUT" | tee -a "$LOG_FILE"
    exit 1
fi

if [ "$FOREIGN_COUNT" -gt 0 ]; then
    log "BLOCK: Foreign workloads detected ($FOREIGN_COUNT). Deployment Aborted."
    # In a real setup, trigger webhook here:
    # curl -X POST https://webhook.site/... -d "Foreign Object Detected"
    echo "$DRY_OUTPUT" | grep "FOREIGN" | tee -a "$LOG_FILE"
    exit 0
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    log "BLOCK: Configuration Errors detected. Deployment Aborted."
    echo "$DRY_OUTPUT" | grep "ERROR" | tee -a "$LOG_FILE"
    exit 0
fi

# --- Step 4: Live Deployment ---
log "Validation Passed (No Foreign/Error). Starting Live Deployment..."
$DSC_SCRIPT --manifest "$STATE_FILE"

log "Workflow Complete."
EOF

chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# 5. Configure Log Rotation
echo "--- Configuring Log Rotation ---"
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

# 6. Install Systemd Units
echo "--- Installing Systemd Units ---"

# Service File
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

# Timer File
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.timer
[Unit]
Description=Run Proxmox IaC Workflow every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

# 7. Activation
echo "--- Activating Service ---"
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.timer

echo ">>> Installation Complete."
echo "    Location: $INSTALL_DIR"
echo "    Service:  systemctl status ${SERVICE_NAME}.timer"
echo "    Logs:     tail -f /var/log/proxmox_dsc.log"
