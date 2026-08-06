#!/usr/bin/env bash
# =============================================================================
# Remediate_Core_Platform_Services.sh - Core logging, cron, SMART, auto-updates
# =============================================================================
#
# SYNOPSIS:
#     Install, repair, and add systemd self-heal (restart on failure) for common
#     platform services: cron, cups-browsed, kernel oops reporting, rsyslog,
#     smartmontools, and automatic security updates.
#
# DESCRIPTION:
#     Fedora: cronie (crond), cups-browsed, abrt+abrt-addon-kerneloops (abrt-oops;
#       equivalent to Debian kerneloops.org client), rsyslog, smartd,
#       dnf-automatic (+ timer).
#     Ubuntu: cron, cups-browsed, kerneloops, rsyslog, smartd, unattended-upgrades
#       (+ timer).
#     Writes systemd drop-ins under /etc/systemd/system/*.d/99-nsight-selfheal.conf
#     for long-running daemons (Restart=on-failure). Update timers are enabled;
#     oneshot update units are not forced Restart=.
#
# EXIT CODES (N-Sight):
#     0    = Success
#     1001 = Warning (non-critical unit or optional stack partial)
#     1002 = Critical (not root, unsupported OS, or critical unit failed)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Core_Platform_Services.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Core_Platform_Services.sh" | sudo bash
#
# NOTES:
#     Platform: Fedora 38+, Ubuntu 22.04+ (single script; runtime detection)
#     Requires: root. Idempotent.
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Core platform services remediation"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/core_platform_services_$(date +%Y%m%d_%H%M%S).log"
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002
readonly SELFHEAL_CONF="99-nsight-selfheal.conf"

OS_ID=""
CRITICAL_FAIL=0
WARNING_FLAG=0

trace() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >>"$LOG_FILE" 2>/dev/null || true
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "CRITICAL: Root privileges required (use sudo)."
        exit "$EXIT_CRITICAL"
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        echo "CRITICAL: /etc/os-release missing; cannot detect OS."
        exit "$EXIT_CRITICAL"
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-}"
    if [[ "$OS_ID" == "fedora" ]]; then
        return 0
    fi
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "pop" ]]; then
        OS_ID="ubuntu"
        return 0
    fi
    echo "CRITICAL: Unsupported OS (need Fedora or Ubuntu); ID=${ID:-unknown}."
    exit "$EXIT_CRITICAL"
}

apply_selfheal_dropin() {
    local unit="$1"
    if [[ -z "$unit" ]]; then
        return 0
    fi
    if ! systemctl cat "$unit" &>/dev/null; then
        trace "Self-heal: unit $unit not present, skip drop-in"
        return 0
    fi
    local dropdir="/etc/systemd/system/${unit}.d"
    local dropfile="${dropdir}/${SELFHEAL_CONF}"
    mkdir -p "$dropdir"
    if [[ -f "$dropfile" ]]; then
        trace "Self-heal: already present $dropfile"
        return 0
    fi
    trace "Self-heal: writing $dropfile"
    cat >"$dropfile" <<'EOF'
[Service]
Restart=on-failure
RestartSec=10
EOF
}

repair_unit() {
    local unit="$1"
    trace "Repair: reset-failed $unit"
    systemctl reset-failed "$unit" >>"$LOG_FILE" 2>&1 || true
}

enable_now() {
    local unit="$1"
    trace "enable --now $unit"
    systemctl enable "$unit" >>"$LOG_FILE" 2>&1 || true
    systemctl restart "$unit" >>"$LOG_FILE" 2>&1 || true
}

verify_active() {
    local unit="$1"
    local optional="${2:-0}"
    if ! systemctl cat "$unit" &>/dev/null; then
        trace "Verify: $unit not installed (optional=$optional)"
        [[ "$optional" == "1" ]] && return 0
        return 1
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        trace "Verify: $unit active"
        return 0
    fi
    local state
    state=$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null || echo "")
    trace "Verify: $unit not active (state=$state)"
    return 1
}

# Optional long-run daemons: not "failed" is acceptable (some stay inactive until used).
verify_not_failed() {
    local unit="$1"
    if ! systemctl cat "$unit" &>/dev/null; then
        trace "Verify: $unit not present, skip"
        return 0
    fi
    local state
    state=$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null || echo "")
    if [[ "$state" == "failed" ]]; then
        trace "Verify: $unit in failed state"
        return 1
    fi
    trace "Verify: $unit OK (state=$state)"
    return 0
}

run_fedora() {
    trace "--- Fedora: dnf install ---"
    if ! dnf install -y cronie cups-browsed abrt abrt-addon-kerneloops rsyslog smartmontools dnf-automatic >>"$LOG_FILE" 2>&1; then
        echo "CRITICAL: dnf install failed (see $LOG_FILE)."
        exit "$EXIT_CRITICAL"
    fi

    local conf="/etc/dnf/automatic.conf"
    if [[ -f "$conf" ]]; then
        if grep -qE '^[[:space:]]*apply_updates[[:space:]]*=' "$conf"; then
            sed -i 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' "$conf"
        fi
        if grep -qE '^[[:space:]]*download_updates[[:space:]]*=' "$conf"; then
            sed -i 's/^[[:space:]]*download_updates[[:space:]]*=.*/download_updates = yes/' "$conf"
        fi
        trace "dnf-automatic.conf tuned for apply/download"
    fi

    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    local -a heal_units=(crond.service cups-browsed.service rsyslog.service smartd.service)
    local u
    for u in "${heal_units[@]}"; do
        repair_unit "$u"
        apply_selfheal_dropin "$u"
    done
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    repair_unit crond.service
    enable_now crond.service
    verify_active crond.service 0 || CRITICAL_FAIL=1

    repair_unit cups-browsed.service
    enable_now cups-browsed.service
    verify_active cups-browsed.service 1 || WARNING_FLAG=1

    repair_unit abrtd.service
    enable_now abrtd.service
    repair_unit abrt-oops.service
    enable_now abrt-oops.service
    apply_selfheal_dropin abrt-oops.service
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    systemctl restart abrt-oops.service >>"$LOG_FILE" 2>&1 || true
    verify_not_failed abrt-oops.service || WARNING_FLAG=1

    repair_unit rsyslog.service
    enable_now rsyslog.service
    verify_active rsyslog.service 0 || CRITICAL_FAIL=1

    repair_unit smartd.service
    enable_now smartd.service
    verify_active smartd.service 1 || WARNING_FLAG=1

    if systemctl cat dnf-automatic.timer &>/dev/null; then
        systemctl enable dnf-automatic.timer >>"$LOG_FILE" 2>&1 || true
        systemctl start dnf-automatic.timer >>"$LOG_FILE" 2>&1 || true
        verify_active dnf-automatic.timer 0 || WARNING_FLAG=1
    else
        trace "dnf-automatic.timer missing"
        WARNING_FLAG=1
    fi
}

run_ubuntu() {
    trace "--- Ubuntu: apt install ---"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >>"$LOG_FILE" 2>&1; then
        echo "CRITICAL: apt-get update failed (see $LOG_FILE)."
        exit "$EXIT_CRITICAL"
    fi
    if ! apt-get install -y cron cups-browsed kerneloops rsyslog smartmontools unattended-upgrades >>"$LOG_FILE" 2>&1; then
        echo "CRITICAL: apt-get install failed (see $LOG_FILE)."
        exit "$EXIT_CRITICAL"
    fi

    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    local -a heal_units=(cron.service cups-browsed.service kerneloops.service rsyslog.service smartd.service)
    local u
    for u in "${heal_units[@]}"; do
        repair_unit "$u"
        apply_selfheal_dropin "$u"
    done
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    repair_unit cron.service
    enable_now cron.service
    verify_active cron.service 0 || CRITICAL_FAIL=1

    repair_unit cups-browsed.service
    enable_now cups-browsed.service
    verify_active cups-browsed.service 1 || WARNING_FLAG=1

    repair_unit kerneloops.service
    enable_now kerneloops.service
    verify_not_failed kerneloops.service || WARNING_FLAG=1

    repair_unit rsyslog.service
    enable_now rsyslog.service
    verify_active rsyslog.service 0 || CRITICAL_FAIL=1

    repair_unit smartd.service
    enable_now smartd.service
    verify_active smartd.service 1 || WARNING_FLAG=1

    if systemctl cat unattended-upgrades.timer &>/dev/null; then
        systemctl enable unattended-upgrades.timer >>"$LOG_FILE" 2>&1 || true
        systemctl start unattended-upgrades.timer >>"$LOG_FILE" 2>&1 || true
        verify_active unattended-upgrades.timer 0 || WARNING_FLAG=1
    else
        trace "unattended-upgrades.timer missing"
        WARNING_FLAG=1
    fi
}

main() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    trace "=========================================="
    trace "$SCRIPT_NAME v$SCRIPT_VERSION host=$(hostname) kernel=$(uname -r)"
    trace "=========================================="

    check_root
    detect_os

    case "$OS_ID" in
        fedora) run_fedora ;;
        ubuntu) run_ubuntu ;;
        *)
            echo "CRITICAL: Internal OS detection error."
            exit "$EXIT_CRITICAL"
            ;;
    esac

    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    if [[ "$CRITICAL_FAIL" -ne 0 ]]; then
        echo "CRITICAL: A required service (cron or rsyslog) is not active after remediation. Log: $LOG_FILE"
        exit "$EXIT_CRITICAL"
    fi
    if [[ "$WARNING_FLAG" -ne 0 ]]; then
        echo "WARNING: Completed with non-critical issues (optional units or timers). Log: $LOG_FILE"
        exit "$EXIT_WARNING"
    fi
    echo "OK: Core platform services installed, enabled, and self-heal drop-ins applied. Log: $LOG_FILE"
    exit "$EXIT_SUCCESS"
}

main "$@"
