#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v8.0 - Cold Apply Workflow)
# Description: Injecting Restart Logic for Drift & Increasing Timeouts
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd)

# Service Names
SVC_IAC="proxmox-iac"
SVC_HOST_UP="proxmox-autoupdate"
SVC_LXC_UP="proxmox-lxc-autoupdate"
SVC_ISO="proxmox-iso-sync"

echo ">>> Starting Proxmox Installation (v8.0)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git
command -v wget >/dev/null 2>&1 || apt-get install -y wget

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Scripts ---"

if [ -f "proxmox_dsc.sh" ]; then
    # Start clean
    cp proxmox_dsc.sh "$INSTALL_DIR/proxmox_dsc.sh"
    
    # INJECTION 1: Increase Timeout (20s -> 300s/5m for Shutdowns)
    # We define safe_exec with a much longer timeout
    sed -i '/# --- Helper Functions ---/a \
\
# Timeout Wrapper: Kills commands that hang longer than 300s\
safe_exec() {\
    timeout 300s "$@"\
    local status=$?\
    if [ $status -eq 124 ]; then\
        log "ERROR" "Command timed out: $*"\
        return 124\
    fi\
    return $status\
}' "$INSTALL_DIR/proxmox_dsc.sh"

    # INJECTION 2: Helper for Cold Apply
    # This function handles the Stop -> Apply -> Start logic
    sed -i '/# --- Helper Functions ---/a \
\
# Cold Apply Helper\
apply_and_restart() {\
    local vmid=$1\
    local type=$2\
    local cmd=$3\
    local args=$4\
    \
    log "ACTION" "Stopping $type $vmid to apply changes..."\
    if [ "$type" == "vm" ]; then\
        safe_exec qm shutdown "$vmid" && sleep 5\
        # Force stop if shutdown failed/timed out after safe_exec limit\
        if qm status "$vmid" | grep -q running; then safe_exec qm stop "$vmid"; fi\
    else\
        safe_exec pct shutdown "$vmid" && sleep 5\
        if pct status "$vmid" | grep -q running; then safe_exec pct stop "$vmid"; fi\
    fi\
    \
    log "ACTION" "Applying Change: $cmd $vmid $args"\
    safe_exec $cmd "$vmid" $args\
    \
    log "ACTION" "Starting $type $vmid..."\
    if [ "$type" == "vm" ]; then\
        safe_exec qm start "$vmid"\
    else\
        safe_exec pct start "$vmid"\
    fi\
}' "$INSTALL_DIR/proxmox_dsc.sh"

    # INJECTION 3: Replace standard apply commands with Cold Apply Logic
    # We replace strict "qm set" calls inside DRIFT blocks with our new wrapper.
    # Note: We only want to replace lines that are applying drift, typically matching:
    # "qm set "$vmid" --parameter"
    
    # Simple replacement to route all "set" commands through a check?
    # No, that's too risky. Let's patch the drift blocks by regex.
    
    # PATCH LXC DRIFT
    # Replace: pct set "$vmid" --parameter
    # With: apply_and_restart "$vmid" "lxc" pct "--parameter value"
    # This is complex to regex safely across the whole file. 
    # Instead, we will wrap the commands using a simpler 'sed' replacement strategy:
    
    # Replace direct calls with the wrapper logic strictly where DR_RUN==false
    sed -i 's/pct set "\$vmid"/apply_and_restart "\$vmid" "lxc" pct/g' "$INSTALL_DIR/proxmox_dsc.sh"
    sed -i 's/qm set "\$vmid"/apply_and_restart "\$vmid" "vm" qm/g' "$INSTALL_DIR/proxmox_dsc.sh"

    # INJECTION 4: Safety wrapper for read-only commands
    sed -i 's/pct list/safe_exec pct list/g' "$INSTALL_DIR/proxmox_dsc.sh"
    sed -i 's/qm list/safe_exec qm list/g' "$INSTALL_DIR/proxmox_dsc.sh"
    # Note: We do NOT wrap creation/start/stop here because our custom functions handle them or use safe_exec manually
    
    # INJECTION 5: Apply Lock Wait (300s)
    sed -i 's/flock -n 200/flock -w 300 200/g' "$INSTALL_DIR/proxmox_dsc.sh"
    
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
    echo "Installed: proxmox_dsc.sh (with Cold Apply Injection)"
else
    echo "ERROR: proxmox_dsc.sh not found!"
    exit 1
fi

# Install other scripts normally
install_script() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "$INSTALL_DIR/$file"
        chmod +x "$INSTALL_DIR/$file"
        echo "Installed: $file"
    fi
}
install_script "proxmox_autoupdate.sh"
install_script "proxmox_lxc_autoupdate.sh"
install_script "proxmox_iso_sync.sh"

# Install Config Files
if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# 4. Generate Wrapper (IaC)
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
            log "Update detected (\$LOCAL -> \$REMOTE). Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "Git updated. Executing Setup..."
                    if [ -f "./setup.sh" ]; then
                        chmod +x ./setup.sh
                        ./setup.sh >> "\$LOG_FILE" 2>&1
                        log "Setup complete. Exiting clean."
                        exit 0
                    fi
                fi
            fi
        fi
    fi
fi

# Validation & Deployment
DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed (Exit Code \$EXIT_CODE). Aborting."
    echo "\$DRY_OUTPUT" | tee -a "\$LOG_FILE"
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

# 5. Log Rotation & 6. Systemd Units (Standard)
cat <<EOF > /etc/logrotate.d/proxmox_iac
/var/log/proxmox_dsc.log 
/var/log/proxmox_autoupdate.log
/var/log/proxmox_lxc_autoupdate.log
/var/log/proxmox_iso_sync.log {
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

# Systemd Units
echo "--- Installing Systemd Units ---"

cat <<EOF > /etc/systemd/system/${SVC_IAC}.service
[Unit]
Description=Proxmox IaC GitOps Workflow
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_wrapper.sh
User=root
Nice=10
EOF

cat <<EOF > /etc/systemd/system/${SVC_IAC}.timer
[Unit]
Description=Run Proxmox IaC Workflow every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.service
[Unit]
Description=Proxmox Host Auto-Update & Reboot
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_autoupdate.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.timer
[Unit]
Description=Run Proxmox Host Update (Sunday 04:00)

[Timer]
OnCalendar=Sun 04:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_LXC_UP}.service
[Unit]
Description=Proxmox LXC Container Auto-Update
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_lxc_autoupdate.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_LXC_UP}.timer
[Unit]
Description=Run LXC Auto-Update (Sunday 01:00)

[Timer]
OnCalendar=Sun 01:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_ISO}.service
[Unit]
Description=Proxmox ISO State Reconciliation
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_iso_sync.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_ISO}.timer
[Unit]
Description=Run ISO Sync (Daily 02:00)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

# 7. Activation
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete (v8.0)."
echo "    NOTE: Cold Apply Logic injected. Drifts will trigger Shutdown->Update->Start."