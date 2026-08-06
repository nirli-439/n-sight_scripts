#!/usr/bin/env bash
# Remediate_Nvidia_Persistenced.sh - Fix NVIDIA persistenced daemon
# For N-Sight RMM deployment (Ubuntu)
#
# SYNOPSIS:
#     Diagnose and fix NVIDIA persistenced service and driver issues.
#
# DESCRIPTION:
#     - Checks for NVIDIA GPU hardware
#     - Installs missing packages
#     - Attempts driver repair if nvidia-smi fails
#     - Enables persistence mode
#     - Exits 0 on success, 1 on failure
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Nvidia_Persistenced.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Nvidia_Persistenced.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Ubuntu/Debian with NVIDIA GPU
#     Logs to: /var/log/nvidia-persistenced-fix.log

set -o errexit
set -o nounset
set -o pipefail

LOG_FILE="/var/log/nvidia-persistenced-fix.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || true

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

service_active() {
  systemctl is-active --quiet "$1"
}

service_enabled() {
  systemctl is-enabled --quiet "$1"
}

has_nvidia_gpu() {
  lspci | grep -qi 'NVIDIA'
}

mod_loaded() {
  lsmod | grep -q "^$1"
}

ensure_repos() {
  log "Ensuring apt indexes are fresh…"
  apt-get update -y >>"$LOG_FILE" 2>&1 || true
}

install_pkg_if_missing() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing missing package: $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
  fi
}

try_start_enable_service() {
  local svc="$1"
  log "Starting $svc…"
  systemctl start "$svc" >>"$LOG_FILE" 2>&1 || true
  if ! service_active "$svc"; then
    log "Service $svc failed to start (will remediate)."
  else
    log "Service $svc is running."
  fi

  if ! service_enabled "$svc"; then
    log "Enabling $svc to start at boot…"
    systemctl enable "$svc" >>"$LOG_FILE" 2>&1 || true
  fi
}

check_nvml_with_nvidia_smi() {
  if have_cmd nvidia-smi; then
    if nvidia-smi -L >/dev/null 2>&1; then
      log "nvidia-smi OK; GPUs detected."
      return 0
    else
      log "nvidia-smi present but failing; driver may be broken."
      return 1
    fi
  else
    log "nvidia-smi not found."
    return 1
  fi
}

enable_persistence_mode() {
  if have_cmd nvidia-smi; then
    log "Enabling persistence mode (nvidia-smi -pm 1)…"
    nvidia-smi -pm 1 >>"$LOG_FILE" 2>&1 || true
  fi
}

autoinstall_driver() {
  log "Attempting automatic NVIDIA driver installation…"
  install_pkg_if_missing "ubuntu-drivers-common"
  # Prefer ubuntu-drivers; fall back to meta package if needed
  if ubuntu-drivers devices | grep -q "driver.*nvidia.*recommended"; then
    log "Using ubuntu-drivers autoinstall…"
    DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall >>"$LOG_FILE" 2>&1 || true
  else
    # As a fallback, install a generic meta package (typically pulls latest tested)
    log "Recommended entry not found; installing nvidia-driver meta package…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-535 >>"$LOG_FILE" 2>&1 || true
  fi
}

purge_nvidia() {
  log "Purging existing NVIDIA packages (safe reset)…"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nvidia*' >>"$LOG_FILE" 2>&1 || true
  apt-get autoremove -y >>"$LOG_FILE" 2>&1 || true
}

reboot_needed=false
mark_reboot() { reboot_needed=true; }

main() {
  require_root
  log "==== Starting NVIDIA persistenced remediation ===="

  if ! has_nvidia_gpu; then
    log "No NVIDIA GPU detected. Nothing to do."
    echo "OK: No NVIDIA GPU present; nvidia-persistenced not required."
    exit 0
  fi

  ensure_repos
  install_pkg_if_missing "pciutils"     # for lspci
  install_pkg_if_missing "systemd"      # service tools
  install_pkg_if_missing "nvidia-persistenced" || true

  # Try to start/enable first (quick win)
  try_start_enable_service "nvidia-persistenced"

  # Verify the service & driver stack
  driver_ok=false
  if service_active "nvidia-persistenced" && check_nvml_with_nvidia_smi; then
    driver_ok=true
  fi

  if [[ "$driver_ok" == "true" ]]; then
    enable_persistence_mode
    log "Driver and service look healthy."
    echo "OK: nvidia-persistenced running; driver healthy."
    exit 0
  fi

  log "Quick start failed or driver unhealthy — entering repair path…"

  # Repair path: (1) ensure kernel modules, (2) reinstall driver if needed
  if ! mod_loaded "nvidia"; then
    log "NVIDIA kernel module not loaded. Attempting modprobe…"
    modprobe nvidia >>"$LOG_FILE" 2>&1 || true
  fi

  # If still bad, reinstall drivers cleanly (purge -> autoinstall)
  if ! check_nvml_with_nvidia_smi; then
    purge_nvidia
    autoinstall_driver
    mark_reboot
  fi

  # Ensure persistenced package exists (some driver branches include it; otherwise separate)
  install_pkg_if_missing "nvidia-persistenced" || true

  # Start/enable again after (re)install
  try_start_enable_service "nvidia-persistenced"

  # Final validation
  if service_active "nvidia-persistenced" && check_nvml_with_nvidia_smi; then
    enable_persistence_mode
    if $reboot_needed; then
      log "Repair completed. A reboot is recommended to finalize the driver install."
      echo "OK: Repaired nvidia-persistenced/driver. Reboot recommended."
      exit 0
    else
      log "Repair completed without reboot."
      echo "OK: nvidia-persistenced running; driver healthy."
      exit 0
    fi
  fi

  # If we reached here, still broken
  log "Repair failed. See $LOG_FILE for details. Possible causes: Secure Boot blocking module, unsupported GPU, or broken repo."
  echo "FAIL: Unable to repair nvidia-persistenced/driver. Check $LOG_FILE (Secure Boot or unsupported GPU may be the cause)."
  exit 1
}

main "$@"
