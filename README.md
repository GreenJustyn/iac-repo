# Proxmox IaC: Idempotent Desired State Configuration

This repository contains a lightweight, bash-based Infrastructure as Code (IaC) solution for Proxmox VE. It utilizes a **Desired State Configuration (DSC)** methodology to ensure that Virtual Machines (QEMU) and Containers (LXC) strictly match a defined JSON manifest.

The solution is designed to be **self-healing**, **idempotent**, and **safe**, operating on a strict "GitOps" workflow.

## 🚀 Key Features

* **Unified Management:** Manages both LXC Containers (`pct`) and Virtual Machines (`qm`) from a single JSON state file.
* **Idempotency:** The script runs every 2 minutes. If the environment matches the state file, no action is taken.
* **Drift Detection:** Automatically corrects configuration drift (e.g., RAM, Cores, Hostname) and enforces Power State (Running/Stopped).
* **Foreign Workload Protection:** Scans the host for "Unmanaged" resources. If a Foreign VM/LXC is detected, **deployment is blocked** to prevent accidental overlaps, and a JSON snippet is generated for easy adoption.
* **GitOps Workflow:** The host automatically updates itself from this git repository before every run.

---

## 🔄 The Workflow (GitOps)

This solution runs automatically via a Systemd Timer. The execution flow is strictly defined to ensure safety:

1.  **Git Pull & Update:** The wrapper checks this repository for new commits. If a new version exists, it pulls the code and re-runs the installer (`setup.sh`) to update the host logic immediately.
2.  **Dry Run Simulation:** The `proxmox_dsc.sh` engine runs in `--dry-run` mode. It simulates changes without applying them.
3.  **Safety & Audit:**
    * It scans the host for **Foreign Workloads** (VMs not in `state.json`).
    * It checks for **Configuration Errors**.
4.  **Decision Gate:**
    * **⛔ BLOCK:** If *any* Foreign Workloads or Errors are found, the process **aborts**. No changes are made. An alert is logged.
    * **✅ DEPLOY:** If the environment is clean and safe, the script runs in "Live" mode to enforce the `state.json` configuration.
5.  **Post-Run:** Logs are rotated and stored in `/var/log/proxmox_dsc.log`.

---

## 🛠️ Installation

### Prerequisites
* Proxmox VE Host (Debian-based).
* Root access.
* Internet connection (for `apt` and `git`).

### Quick Start
1.  **SSH into your Proxmox Host.**
2.  **Clone this repository:**
    ```bash
    cd /root
    git clone [https://github.com/your-user/proxmox-iac.git](https://github.com/your-user/proxmox-iac.git) iac-repo
    cd iac-repo
    ```
3.  **Run the Setup Script:**
    ```bash
    chmod +x setup.sh
    ./setup.sh
    ```

**That's it.** The `setup.sh` script will:
* Install dependencies (`jq`, `git`).
* Deploy the scripts to `/root/iac/`.
* Configure Log Rotation.
* Install and Start the Systemd Timer (running every 2 minutes).

---

## 📄 Configuration (`state.json`)

Your infrastructure is defined in `state.json`. The script supports two types of resources: `"lxc"` and `"vm"`.

### Example Manifest
```json
[
  {
    "type": "lxc",
    "vmid": 100,
    "hostname": "web-01",
    "template": "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst",
    "memory": 1024,
    "cores": 2,
    "net0": "name=eth0,bridge=vmbr0,ip=dhcp",
    "storage": "local-lvm:8",
    "state": "running"
  },
  {
    "type": "vm",
    "vmid": 200,
    "hostname": "db-01",
    "template": "local:iso/debian-12.0.0-amd64-netinst.iso",
    "memory": 4096,
    "cores": 4,
    "net0": "virtio,bridge=vmbr0",
    "storage": "local-lvm:32",
    "state": "running"
  }
]
