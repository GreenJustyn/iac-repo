#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v4.0 - Wrapper & Auto-Updater)
# Description: GitOps Installer for Proxmox IaC + Host Auto-Updates
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
# Capture the ACTUAL current directory where this repo lives
REPO_DIR=$(pwd)
SERVICE_IAC="proxmox-iac"
SERVICE_UPDATE="proxmox-autoupdate"

echo ">>> Starting Proxmox Installation (v4.0)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
pkill -f "proxmox_dsc.sh" || true
pkill -f "proxmox_wrapper.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Core Scripts ---"

# A) Install DSC Script (with Lock Fix)
if [ -f "proxmox_dsc.sh" ]; then
    sed 's/flock -n 200/flock -w 60 200/g' proxmox_dsc.sh > "$INSTALL_DIR/proxmox_dsc.sh"
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
else
    echo "ERROR: proxmox_dsc.sh not found!"
    exit 1
fi

# B) Install Auto-Update Script
if [ -f "proxmox_autoupdate.sh" ]; then
    cp proxmox_autoupdate.sh "$INSTALL_DIR/proxmox_autoupdate.sh"
    chmod +x "$INSTALL_DIR/proxmox_autoupdate.sh"
else
    echo "ERROR: proxmox_autoupdate.sh not found!"
    exit 1
fi

# C) Install State File
if [ -f "state.json" ]; then
    cp state.json "$INSTALL_DIR/state.json"
else
    echo "[]" > "$INSTALL_DIR/state.json"
fi

# 4. Generate Smart Wrapper (For IaC Workflow)
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] \$1" | tee -a "\$LOG_FILE"; }

# Git Auto-Update Logic
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})
        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "Update detected. Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "Git updated. Re-installing..."
                    [ -f "./setup.sh" ] && chmod +x ./setup.sh && ./setup.sh
                    exec "\$0"
                fi
            fi
        fi
    fi
fi

# Validation & Deployment
DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed. Aborting."
    exit 1
fi

if echo "\$DRY_OUTPUT" | grep -q "FOREIGN"; then
    log "BLOCK: Foreign workloads detected. Aborting."
    echo "\$DRY_OUTPUT" | grep "FOREIGN" | tee -a "\$LOG_FILE"
    exit 0
fi

if echo "\$DRY_OUTPUT" | grep -q "ERROR"; then
    log "BLOCK: Errors detected. Aborting."
    exit 0
fi

log "Deploying..."
"\$DSC_SCRIPT" --manifest "\$STATE_FILE"
EOF

chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# 5. Log Rotation (Combined)
cat <<EOF > /etc/logrotate.d/proxmox_iac
/var/log/proxmox_dsc.log 
/var/log/proxmox_autoupdate.log {
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

# 6. Systemd Units

echo "--- Installing Systemd Units ---"

# --- Unit 1: IaC (Existing) ---
cat <<EOF > /etc/systemd/system/${SERVICE_IAC}.service
[Unit]
Description=Proxmox IaC GitOps Workflow
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_wrapper.sh
User=root
Nice=10
EOF

cat <<EOF > /etc/systemd/system/${SERVICE_IAC}.timer
[Unit]
Description=Run Proxmox IaC Workflow every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

# --- Unit 2: Auto-Update (New) ---
cat <<EOF > /etc/systemd/system/${SERVICE_UPDATE}.service
[Unit]
Description=Proxmox Host Auto-Update and Reboot
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_autoupdate.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SERVICE_UPDATE}.timer
[Unit]
Description=Run Proxmox Host Update (Weekly)

[Timer]
# Run every Sunday at 04:00 AM
OnCalendar=Sun 04:00
# Ensure it doesn't run immediately on boot if missed, to prevent reboot loops
Persistent=false

[Install]
WantedBy=timers.target
EOF

# 7. Activation
systemctl daemon-reload
systemctl enable --now ${SERVICE_IAC}.timer
systemctl enable --now ${SERVICE_UPDATE}.timer

echo ">>> Installation Complete (v4.0)."
echo "    IaC Timer:    Every 2 minutes"
echo "    Update Timer: Sunday at 04:00 AM"
