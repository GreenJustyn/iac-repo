#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v3.3 - Fixes Git Loop & Race Conditions)
# Description: GitOps Installer for Proxmox IaC.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
# Capture the ACTUAL current directory where this repo lives
REPO_DIR=$(pwd)
SERVICE_NAME="proxmox-iac"

echo ">>> Starting Proxmox IaC Installation (v3.3)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
if crontab -l 2>/dev/null | grep -q "proxmox_dsc.sh"; then
    crontab -l | grep -v "proxmox_dsc.sh" | crontab -
fi
pkill -f "proxmox_dsc.sh" || true
pkill -f "proxmox_wrapper.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Core Scripts (with Lock Fix)
echo "--- Installing Scripts ---"

if [ -f "proxmox_dsc.sh" ]; then
    # Inject the "Wait 60s" lock fix into the destination file
    sed 's/flock -n 200/flock -w 60 200/g' proxmox_dsc.sh > "$INSTALL_DIR/proxmox_dsc.sh"
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
else
    echo "ERROR: proxmox_dsc.sh not found in $REPO_DIR!"
    exit 1
fi

if [ -f "state.json" ]; then
    cp state.json "$INSTALL_DIR/state.json"
else
    echo "[]" > "$INSTALL_DIR/state.json"
fi

# 4. Generate Smart Wrapper
# We inject the captured $REPO_DIR into the script
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] \$1" | tee -a "\$LOG_FILE"; }

# --- Step 1: Git Auto-Update (Loop Protected) ---
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    
    # Check remote only if network is up
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})

        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "Update detected. Attempting pull..."
            
            # Capture output and exit code
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. Skipping update to prevent loop. Details: \$output"
            else
                # Verify we actually moved
                NEW_LOCAL=\$(git rev-parse HEAD)
                if [ "\$NEW_LOCAL" != "\$LOCAL" ]; then
                    log "Git updated successfully (\$LOCAL -> \$NEW_LOCAL). Re-installing and Restarting..."
                    
                    # Run setup to apply changes
                    if [ -f "./setup.sh" ]; then
                        chmod +x ./setup.sh
                        ./setup.sh
                    fi
                    
                    # Restart wrapper process to use new code
                    exec "\$0"
                else
                    log "WARN: Git pull succeeded but HEAD did not move. Continuing without restart."
                fi
            fi
        fi
    else
        log "WARN: Unable to fetch from git remote. Skipping update check."
    fi
else
    log "WARN: No git repo found at \$REPO_DIR. Skipping update."
fi

# --- Step 2: Dry Run ---
log "Starting Dry Run..."
# Run Dry Run, capturing both STDOUT and STDERR
DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

FOREIGN_COUNT=\$(echo "\$DRY_OUTPUT" | grep -c "FOREIGN")
ERROR_COUNT=\$(echo "\$DRY_OUTPUT" | grep -c "ERROR")

# --- Step 3: Decision Logic ---
if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed (Exit Code \$EXIT_CODE). Aborting."
    echo "\$DRY_OUTPUT" | tee -a "\$LOG_FILE"
    exit 1
fi

if [ "\$FOREIGN_COUNT" -gt 0 ]; then
    log "BLOCK: Foreign workloads detected (\$FOREIGN_COUNT). Aborting."
    echo "\$DRY_OUTPUT" | grep "FOREIGN" | tee -a "\$LOG_FILE"
    exit 0
fi

if [ "\$ERROR_COUNT" -gt 0 ]; then
    log "BLOCK: Errors detected. Aborting."
    echo "\$DRY_OUTPUT" | grep "ERROR" | tee -a "\$LOG_FILE"
    exit 0
fi

# --- Step 4: Deployment ---
log "Validation Passed. Deploying..."
"\$DSC_SCRIPT" --manifest "\$STATE_FILE"
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

echo ">>> Installation Complete (v3.3). Loop protection enabled."
