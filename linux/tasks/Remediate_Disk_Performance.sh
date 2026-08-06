#!/usr/bin/env bash
# Remediate_Disk_Performance.sh - Fix N-sight disk performance monitoring
# For N-Sight RMM deployment
#
# SYNOPSIS:
#     Fix disk performance monitoring for N-sight agent.
#
# DESCRIPTION:
#     - Installs sysstat, smartmontools, nvme-cli
#     - Enables sysstat collection
#     - Seeds initial performance data
#     - Runs fstrim on SSDs
#     - Checks SMART health
#     - Restarts N-sight agent to refresh metrics
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Disk_Performance.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Disk_Performance.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Platform: Linux (Debian/Ubuntu, RHEL/Fedora)
#     Logs to: /var/log/nsight_disk_perf_autofix.log

set -euo pipefail

LOG="/var/log/nsight_disk_perf_autofix.log"
touch "$LOG" || true

info(){ echo "[INFO] $*" | tee -a "$LOG"; }
warn(){ echo "[WARN] $*" | tee -a "$LOG"; }
fail(){ echo "[FAIL] $*" | tee -a "$LOG"; }

# --- 0) Sanity: which disks does the box report? ---
MAP=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
if [[ -z "$MAP" ]]; then
  echo "ERROR: No disks detected by lsblk." | tee -a "$LOG"
  exit 2
fi
info "Disks: $(echo "$MAP" | xargs)"

# --- 1) Prereqs: sysstat (iostat), smartmontools, nvme-cli where relevant ---
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$LOG" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y sysstat smartmontools nvme-cli >>"$LOG" 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf -y install sysstat smartmontools nvme-cli >>"$LOG" 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum -y install sysstat smartmontools nvme-cli >>"$LOG" 2>&1 || true
fi

# --- 2) Enable sysstat collection if disabled (Ubuntu/Debian default is "false") ---
if [[ -f /etc/default/sysstat ]]; then
  if grep -q '^ENABLED="false"' /etc/default/sysstat; then
    info "Enabling sysstat collection"
    sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
  fi
fi

# Start/enable services or timers (works for both cron- and systemd-based)
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now sysstat >/dev/null 2>&1 || true
systemctl enable --now sysstat-collect >/dev/null 2>&1 || true
systemctl enable --now sysstat-summary >/dev/null 2>&1 || true
service sysstat start >/dev/null 2>&1 || true

# Seed a few seconds of data so iostat has something recent
# (Without this, some agents think "no data" == failure)
if command -v sadc >/dev/null 2>&1; then
  mkdir -p /var/log/sysstat
  sadc -S XALL -F -L 1 3 /var/log/sysstat/sa$(date +%d) >/dev/null 2>&1 || true
fi

# --- 3) Verify per-disk iostat is readable for all block devices ---
if ! command -v iostat >/dev/null 2>&1; then
  echo "ERROR: iostat not available after install." | tee -a "$LOG"
  exit 2
fi

# Collect a quick sample
IOSTAT_OUT=$(iostat -xdm 1 2 2>/dev/null || true)
echo "$IOSTAT_OUT" >>"$LOG"

BAD=()
for d in $MAP; do
  NAME=$(basename "$d")
  if ! echo "$IOSTAT_OUT" | awk '/^Device:/{p=1;next} p' | awk '{print $1}' | grep -qx "$NAME"; then
    BAD+=("$NAME")
  fi
done

# --- 4) Safe optimizations (TRIM SSDs) ---
if command -v fstrim >/dev/null 2>&1; then
  info "Running fstrim -av"
  fstrim -av >>"$LOG" 2>&1 || true
fi

# --- 5) Smart health quick check (non-fatal) ---
for d in $MAP; do
  if [[ "$d" == /dev/nvme* ]]; then
    command -v nvme >/dev/null 2>&1 && nvme smart-log "$d" >>"$LOG" 2>&1 || true
  else
    command -v smartctl >/dev/null 2>&1 && smartctl -H "$d" >>"$LOG" 2>&1 || true
  fi
done

# --- 6) N-sight agent bounce to trigger recheck (try common service names) ---
for svc in nsight-agent nagent advanced-monitoring-agent nable-agent ncentral-agent rmmagent monitoring-agent; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
    info "Restarting agent: $svc"
    systemctl restart "$svc" >/dev/null 2>&1 || true
    break
  fi
done

# --- 7) Report outcome for RMM ---
if ((${#BAD[@]})); then
  echo "WARNING: Per-disk performance data missing for: ${BAD[*]}. sysstat enabled/seeded; agent restarted. Recheck should clear after a few minutes."
  exit 1
else
  echo "OK: Per-disk performance data is available (iostat working). sysstat enabled and agent restarted."
  exit 0
fi
