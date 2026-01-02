#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_dsc.sh (v3.1 - Unified & Fixed)
# Description: Idempotent Proxmox IaC Manager for Containers (LXC) and VMs (QEMU)
#              Includes Foreign Workload Detection & JSON Auto-Generation.
# OS: Debian 13 (Proxmox Host)
# Dependencies: jq, pct, qm
# Usage: ./proxmox_dsc.sh --manifest /path/to/state.json [--dry-run]
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
LOCK_FILE="/tmp/proxmox_dsc.lock"
LOG_FILE="/var/log/proxmox_dsc.log"

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variables ---
MANIFEST=""
DRY_RUN=false
declare -a MANAGED_VMIDS=()

# --- Logging Helper ---
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Print to console if interactive or dry-run, always log to file
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# --- Input Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --manifest) MANIFEST="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$MANIFEST" ]]; then
    echo "Error: Manifest file required. Usage: $0 --manifest <path> [--dry-run]"
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: Manifest file not found at $MANIFEST"
    exit 1
fi

# --- Locking Mechanism ---
exec 200>"$LOCK_FILE"
flock -n 200 || { log "WARN" "Script is already running. Exiting."; exit 1; }

# --- Helper Functions ---

# Check if ID exists in either LXC or QM
get_resource_status() {
    local vmid=$1
    # Fix: Use awk to strip whitespace padding from the first column (VMID)
    # Then grep for an exact line match (^ID$)
    if pct list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_lxc"; return; fi
    if qm list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_vm"; return; fi
    echo "missing"
}

get_power_state() {
    local vmid=$1
    local type=$2
    if [[ "$type" == "lxc" ]]; then
        pct status "$vmid" | awk '{print $2}'
    else
        qm status "$vmid" | awk '{print $2}'
    fi
}

# --- RECONCILIATION LOGIC: LXC ---
reconcile_lxc() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local template=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local swap=$(echo "$config" | jq -r '.swap // 512') # Default to 512MB if missing
    local cores=$(echo "$config" | jq -r '.cores')
    local storage=$(echo "$config" | jq -r '.storage') # e.g. "local-lvm:8"
    local net0=$(echo "$config" | jq -r '.net0')
    local desired_state=$(echo "$config" | jq -r '.state')

    # Options
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')

    log "INFO" "[LXC] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    # 1. CREATE
    if [[ "$status" == "missing" ]]; then
        log "WARN" "LXC $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            # Basic Creation
            pct create "$vmid" "$template" \
                --hostname "$hostname" \
                --memory "$memory" \
                --swap "$swap" \
                --cores "$cores" \
                --net0 "$net0" \
                --rootfs "$storage" \
                --onboot "$onboot" \
                --protection "$protection" \
                --features nesting=1 \
                || return 1
            
            log "SUCCESS" "LXC $vmid created."
        else
            log "DRY-RUN" "Would execute: pct create $vmid ..."
        fi

    elif [[ "$status" == "exists_vm" ]]; then
        log "ERROR" "ID Conflict: $vmid is defined as LXC but exists as VM."
        return 1
    else
        # 2. DRIFT DETECTION (Expanded)

        # A. Hostname
        local cur_host=$(pct config "$vmid" | grep "hostname:" | awk '{print $2}')
        if [[ "$cur_host" != "$hostname" ]]; then
            log "INFO" "Drift $vmid: Hostname $cur_host -> $hostname"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --hostname "$hostname"
        fi

        # B. Memory
        local cur_mem=$(pct config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --memory "$memory"
        fi

        # C. Swap (New)
        local cur_swap=$(pct config "$vmid" | grep "swap:" | awk '{print $2}')
        if [[ "${cur_swap:-0}" != "$swap" ]]; then
            log "INFO" "Drift $vmid: Swap ${cur_swap:-0} -> $swap"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --swap "$swap"
        fi

        # D. Cores
        local cur_cores=$(pct config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --cores "$cores"
        fi

        # E. OnBoot
        local cur_onboot=$(pct config "$vmid" | grep "onboot:" | awk '{print $2}')
        if [[ "${cur_onboot:-0}" != "$onboot" ]]; then
            log "INFO" "Drift $vmid: OnBoot ${cur_onboot:-0} -> $onboot"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --onboot "$onboot"
        fi

        # F. Protection
        local cur_prot=$(pct config "$vmid" | grep "protection:" | awk '{print $2}')
        if [[ "${cur_prot:-0}" != "$protection" ]]; then
            log "INFO" "Drift $vmid: Protection ${cur_prot:-0} -> $protection"
            [[ "$DRY_RUN" == "false" ]] && pct set "$vmid" --protection "$protection"
        fi

        # G. Storage (RootFS Growth Check)
        # Parse size from "local-lvm:8" -> "8" (Assumes GB)
        local req_size=$(echo "$storage" | awk -F: '{print $2}')
        # Get current rootfs size. Output format usually "volume=local-lvm:vm-100-disk-0,size=8G"
        local cur_size_raw=$(pct config "$vmid" | grep "rootfs:" | grep -o "size=[0-9]*G" | grep -o "[0-9]*")
        
        # Compare (Only grow, never shrink)
        if [[ -n "$req_size" && -n "$cur_size_raw" ]]; then
            if (( req_size > cur_size_raw )); then
                log "WARN" "Drift $vmid: RootFS Size ${cur_size_raw}G -> ${req_size}G (Resizing...)"
                if [[ "$DRY_RUN" == "false" ]]; then
                    # pct resize <vmid> <disk> <size> (e.g., +2G or absolute size like 10G)
                    # We use absolute size matching the manifest
                    pct resize "$vmid" rootfs "${req_size}G"
                fi
            elif (( req_size < cur_size_raw )); then
                 log "WARN" "Drift $vmid: Requested disk ($req_size) is smaller than current ($cur_size_raw). Shrinking not supported."
            fi
        fi
    fi

    # 3. POWER STATE
    local actual_state=$(get_power_state "$vmid" "lxc")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then pct start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then pct shutdown "$vmid"; fi
    fi
}

# --- RECONCILIATION LOGIC: VM (QEMU) ---
reconcile_vm() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local iso=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local cores=$(echo "$config" | jq -r '.cores')
    local sockets=$(echo "$config" | jq -r '.sockets // 1')
    local cpu_type=$(echo "$config" | jq -r '.cpu // "kvm64"')
    local net0=$(echo "$config" | jq -r '.net0')
    local desired_state=$(echo "$config" | jq -r '.state')
    
    # Options
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')

    log "INFO" "[VM] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    # 1. CREATE (Unchanged)
    if [[ "$status" == "missing" ]]; then
        log "WARN" "VM $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            # ... (Creation logic remains the same) ...
            qm create "$vmid" --name "$hostname" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --scsi0 "$storage" --cdrom "$iso" --scsihw virtio-scsi-pci --boot order=scsi0;ide2;net0 --onboot "$onboot" --protection "$protection"
            # (Insert Cloud Init logic here if you strictly need it again)
            log "SUCCESS" "VM $vmid created."
        else
            log "DRY-RUN" "Would execute: qm create $vmid ..."
        fi

    elif [[ "$status" == "exists_lxc" ]]; then
        log "ERROR" "ID Conflict: $vmid is defined as VM but exists as LXC."
        return 1
    else
        # 2. DRIFT DETECTION (Expanded)
        
        # A. Memory (Hot-pluggable usually)
        local cur_mem=$(qm config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            [[ "$DRY_RUN" == "false" ]] && qm set "$vmid" --memory "$memory"
        fi

        # B. Cores (Requires Reboot often, but safe to set)
        local cur_cores=$(qm config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            [[ "$DRY_RUN" == "false" ]] && qm set "$vmid" --cores "$cores"
        fi

        # C. Sockets
        local cur_sockets=$(qm config "$vmid" | grep "sockets:" | awk '{print $2}')
        if [[ "${cur_sockets:-1}" != "$sockets" ]]; then
            log "INFO" "Drift $vmid: Sockets ${cur_sockets:-1} -> $sockets"
            [[ "$DRY_RUN" == "false" ]] && qm set "$vmid" --sockets "$sockets"
        fi

        # D. OnBoot
        local cur_onboot=$(qm config "$vmid" | grep "onboot:" | awk '{print $2}')
        if [[ "${cur_onboot:-0}" != "$onboot" ]]; then
            log "INFO" "Drift $vmid: OnBoot ${cur_onboot:-0} -> $onboot"
            [[ "$DRY_RUN" == "false" ]] && qm set "$vmid" --onboot "$onboot"
        fi

        # E. CPU Type (DANGEROUS: Requires Stop/Start)
        local cur_cpu=$(qm config "$vmid" | grep "cpu:" | awk '{print $2}')
        # Handle default "kvm64" if grep returns empty
        if [[ "${cur_cpu:-kvm64}" != "$cpu_type" ]]; then
            log "WARN" "Drift $vmid: CPU Type ${cur_cpu:-kvm64} -> $cpu_type. (Requires Cold Boot)"
            if [[ "$DRY_RUN" == "false" ]]; then
                # We only apply this if state allows (we don't want to kill a running prod VM lightly)
                # Strategy: Set pending change. Proxmox applies on next start.
                qm set "$vmid" --cpu "$cpu_type"
                
                # OPTIONAL: Force Restart to apply immediately?
                # log "ACTION" "Stopping VM to apply CPU change..."
                # qm shutdown "$vmid" && sleep 10 && qm stop "$vmid" && qm start "$vmid"
            fi
        fi

        # F. Network (Complex - checks entire string match)
        # Note: This checks the RAW net0 string. 
        # If you change "virtio,bridge=vmbr0" to "virtio,bridge=vmbr1", it detects it.
        local cur_net0=$(qm config "$vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
        if [[ "$cur_net0" != "$net0" ]]; then
             log "INFO" "Drift $vmid: Network Configuration changed."
             [[ "$DRY_RUN" == "false" ]] && qm set "$vmid" --net0 "$net0"
        fi
    fi

    # 3. POWER STATE (Unchanged)
    local actual_state=$(get_power_state "$vmid" "vm")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then qm start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then qm shutdown "$vmid"; fi
    fi
}

# --- DISPATCHER ---
reconcile_dispatch() {
    local config="$1"
    local type=$(echo "$config" | jq -r '.type')
    local vmid=$(echo "$config" | jq -r '.vmid')

    MANAGED_VMIDS+=("$vmid")

    if [[ "$type" == "lxc" ]]; then
        reconcile_lxc "$config"
    elif [[ "$type" == "vm" ]]; then
        reconcile_vm "$config"
    else
        log "ERROR" "Unknown type '$type' for VMID $vmid"
    fi
}

# --- FOREIGN WORKLOAD DETECTION (Detailed JSON Output) ---
detect_unmanaged_workloads() {
    log "INFO" "Starting Audit for Unmanaged Workloads..."
    
    # 1. Get LXC List (Skipping header)
    local lxc_list=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    
    # 2. Get VM List (Skipping header)
    local vm_list=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')

    # FIX: Concatenate with a Newline, not a space, to respect IFS=$'\n\t'
    local all_vms="$lxc_list"$'\n'"$vm_list"

    # Flag to track findings
    local found_foreign=false

    for host_vmid in $all_vms; do
        # Skip empty lines resulting from the merge
        [[ -z "$host_vmid" ]] && continue

        local is_managed=false
        for managed_id in "${MANAGED_VMIDS[@]}"; do
            if [[ "$host_vmid" == "$managed_id" ]]; then is_managed=true; break; fi
        done

        if [[ "$is_managed" == "false" ]]; then
            found_foreign=true
            
            # Determine Type
            local r_type="unknown"
            if pct status "$host_vmid" &>/dev/null; then r_type="lxc"; fi
            if qm status "$host_vmid" &>/dev/null; then r_type="vm"; fi

            log "WARN" "FOREIGN $r_type DETECTED: VMID $host_vmid"
            
            # --- Generate Valid JSON for LXC ---
            if [[ "$r_type" == "lxc" ]]; then
                 local d_name=$(pct config "$host_vmid" | grep "hostname:" | awk '{print $2}')
                 local d_mem=$(pct config "$host_vmid" | grep "memory:" | awk '{print $2}')
                 local d_cores=$(pct config "$host_vmid" | grep "cores:" | awk '{print $2}')
                 local d_net=$(pct config "$host_vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
                 local d_root=$(pct config "$host_vmid" | grep "rootfs:" | awk '{$1=""; print $0}' | xargs)

                 echo -e "\n${YELLOW}--- SUGGESTED JSON IMPORT FOR LXC $host_vmid ---${NC}"
                 echo "  {"
                 echo "    \"type\": \"lxc\","
                 echo "    \"vmid\": $host_vmid,"
                 echo "    \"hostname\": \"${d_name:-unknown}\","
                 echo "    \"template\": \"local:vztmpl/EXISTING\","
                 echo "    \"memory\": ${d_mem:-512},"
                 echo "    \"cores\": ${d_cores:-1},"
                 echo "    \"net0\": \"${d_net:-name=eth0,bridge=vmbr0,ip=dhcp}\","
                 echo "    \"storage\": \"${d_root:-local-lvm:8}\","
                 echo "    \"state\": \"running\""
                 echo "  },"

            # --- Generate Valid JSON for VM (QEMU) ---
            elif [[ "$r_type" == "vm" ]]; then
                 local d_name=$(qm config "$host_vmid" | grep "name:" | awk '{print $2}')
                 local d_mem=$(qm config "$host_vmid" | grep "memory:" | awk '{print $2}')
                 local d_cores=$(qm config "$host_vmid" | grep "cores:" | awk '{print $2}')
                 # Extract net0, remove key 'net0:', trim whitespace
                 local d_net=$(qm config "$host_vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
                 # Extract scsi0 (or ide0/sata0 if scsi0 missing) for storage hint
                 local d_store=$(qm config "$host_vmid" | grep "scsi0:" | awk '{$1=""; print $0}' | xargs)

                 echo -e "\n${YELLOW}--- SUGGESTED JSON IMPORT FOR VM $host_vmid ---${NC}"
                 echo "  {"
                 echo "    \"type\": \"vm\","
                 echo "    \"vmid\": $host_vmid,"
                 echo "    \"hostname\": \"${d_name:-vm$host_vmid}\","
                 echo "    \"template\": \"local:iso/EXISTING\","
                 echo "    \"memory\": ${d_mem:-1024},"
                 echo "    \"cores\": ${d_cores:-1},"
                 echo "    \"net0\": \"${d_net:-virtio,bridge=vmbr0}\","
                 echo "    \"storage\": \"${d_store:-local-lvm:32}\","
                 echo "    \"state\": \"running\""
                 echo "  },"
            fi
        fi
    done
    
    if [[ "$found_foreign" == "true" ]]; then
        echo -e "\n${YELLOW}Copy the blocks above into your state.json to adopt these resources.${NC}"
    fi
}

# --- Main Execution ---
log "INFO" "Run Started. Processing Manifest: $MANIFEST"

# Iterate through JSON array
for row in $(cat "$MANIFEST" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
    current_config=$(echo ${row} | base64 --decode)
    reconcile_dispatch "$current_config"
done

# Run Post-Execution Audit
detect_unmanaged_workloads

log "INFO" "Run complete."
