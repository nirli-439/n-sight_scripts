#!/usr/bin/env bash
# =============================================================================
# Remediate_Fedora_Scheduled_Maintenance.sh - smartd, dnf-automatic, cron (Fedora)
# =============================================================================
#
# SYNOPSIS:
#     Install and enable periodic maintenance on Fedora: SMART monitoring,
#     automatic updates (equivalent to Debian unattended-upgrades), and cron.
#
# DESCRIPTION:
#     For Fedora endpoints this script:
#     - smartmontools: installs if needed and enables smartd (S.M.A.R.T. disk checks)
#     - dnf-automatic: installs, configures download/apply of updates, enables
#       dnf-automatic.timer (Fedora’s supported replacement for unattended-upgrades)
#     - cronie: installs if needed and enables crond (scheduled jobs)
#
#     On non-Fedora systems the script exits with a warning and does nothing else.
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning (wrong distro, or partial failure)
#     1002 = Critical/Error
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Fedora_Scheduled_Maintenance.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Fedora_Scheduled_Maintenance.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+ only
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Fedora scheduled maintenance"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/fedora_scheduled_maintenance_$(date +%Y%m%d_%H%M%S).log"
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        echo ""
        echo "CRITICAL: Root privileges required"
        exit "$EXIT_CRITICAL"
    fi
}

is_fedora() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        [[ "${ID:-}" == "fedora" ]] && return 0
    fi
    [[ -f /etc/fedora-release ]]
}

configure_dnf_automatic() {
    local conf="/etc/dnf/automatic.conf"
    if [[ ! -f "$conf" ]]; then
        log "Missing $conf after dnf-automatic install" "ERROR"
        return 1
    fi
    # Enable download + apply (Fedora equivalent of unattended-upgrades)
    if grep -qE '^[[:space:]]*apply_updates[[:space:]]*=' "$conf"; then
        sed -i 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' "$conf"
    fi
    if grep -qE '^[[:space:]]*download_updates[[:space:]]*=' "$conf"; then
        sed -i 's/^[[:space:]]*download_updates[[:space:]]*=.*/download_updates = yes/' "$conf"
    fi
    log "dnf-automatic: set apply_updates and download_updates in $conf" "SUCCESS"
}

enable_service() {
    local unit="$1"
    if ! systemctl list-unit-files "${unit}" &>/dev/null; then
        log "Unit not found: ${unit}" "WARN"
        return 1
    fi
    systemctl enable "${unit}" >> "$LOG_FILE" 2>&1
    systemctl restart "${unit}" >> "$LOG_FILE" 2>&1 || true
    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
        log "${unit}: active" "SUCCESS"
        return 0
    fi
    log "${unit}: not active after enable/start" "WARN"
    return 1
}

# =============================================================================
# MAIN
# =============================================================================

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "Log: $LOG_FILE"
log ""

check_root

if ! is_fedora; then
    log "Not Fedora — this task is Fedora-only; no changes made." "WARN"
    echo ""
    echo "WARNING: Not Fedora; skipped."
    exit "$EXIT_WARNING"
fi

if ! command -v dnf &>/dev/null; then
    log "dnf not found" "ERROR"
    echo "CRITICAL: dnf required"
    exit "$EXIT_CRITICAL"
fi

log "--- Installing packages ---"
# smartmontools: smartd | dnf-automatic: unattended-upgrades equivalent | cronie: cron
if ! dnf install -y smartmontools dnf-automatic cronie >> "$LOG_FILE" 2>&1; then
    log "dnf install failed" "ERROR"
    echo "CRITICAL: Package installation failed"
    exit "$EXIT_CRITICAL"
fi

log "Packages present: smartmontools, dnf-automatic, cronie" "SUCCESS"

configure_dnf_automatic || log "Could not tune dnf-automatic.conf" "WARN"

FAILED=0
log "--- Enabling services ---"

enable_service "smartd.service" || FAILED=1
enable_service "crond.service" || FAILED=1

if systemctl list-unit-files "dnf-automatic.timer" &>/dev/null; then
    systemctl enable dnf-automatic.timer >> "$LOG_FILE" 2>&1
    systemctl start dnf-automatic.timer >> "$LOG_FILE" 2>&1
    if systemctl is-active --quiet dnf-automatic.timer 2>/dev/null; then
        log "dnf-automatic.timer: active (scheduled automatic updates)" "SUCCESS"
    else
        log "dnf-automatic.timer: not active" "WARN"
        FAILED=1
    fi
else
    log "dnf-automatic.timer not found" "WARN"
    FAILED=1
fi

log ""
log "=========================================="
if [[ "$FAILED" -ne 0 ]]; then
    echo "WARNING: Fedora maintenance automation completed with warnings (see log)."
    exit "$EXIT_WARNING"
fi

echo "OK: smartd, dnf-automatic (timer), and crond are enabled on Fedora."
exit "$EXIT_SUCCESS"
