#!/usr/bin/env bash
# =============================================================================
# Install_N-Sight_Support_Linux.sh - Universal Linux Support Requirements
# =============================================================================
#
# SYNOPSIS:
#     Installs requirements for N-Sight RMM support (logging, disk health, SSH).
#
# DESCRIPTION:
#     Installs and configures the following for N-Sight RMM monitoring:
#     - rsyslog          : System logging daemon
#     - smartmontools    : S.M.A.R.T. disk health monitoring
#     - cups             : Print service
#     - cron/cronie      : Scheduled task scheduler
#     - openssh-server   : SSH for remote access
#     - admin user       : User "admin" (default) with password "1111"
#     - firewall         : Opens port 22 (ufw or firewalld)
#
#     All services are enabled and started for N-Sight agent log collection.
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning
#     1002 = Critical/Error
#
# EXECUTION:
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Install_N-Sight_Support_Linux.sh" | sudo bash
#     sudo bash /path/to/Install_N-Sight_Support_Linux.sh [USERNAME]
#
# NOTES:
#     Author: IT Admin
#     Version: 2.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, Ubuntu 22.04+ (Universal GNOME focus)
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="N-Sight Support (Linux)"
readonly SCRIPT_VERSION="2.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/n-sight_support_linux_$(date +%Y%m%d_%H%M%S).log"
readonly ADMIN_PASSWORD="1111"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Target user: first argument or default "admin"
TARGET_USER="${1:-admin}"

# =============================================================================
# FUNCTIONS
# =============================================================================

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
        exit $EXIT_CRITICAL
    fi
}

get_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    else
        echo ""
    fi
}

get_sudo_group() {
    if getent group wheel &>/dev/null; then
        echo "wheel"
    elif getent group sudo &>/dev/null; then
        echo "sudo"
    else
        echo "sudo"
    fi
}

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

check_root

PKG_MGR=$(get_pkg_mgr)
if [[ -z "$PKG_MGR" ]]; then
    log "Unsupported distro (Fedora or Ubuntu required)" "ERROR"
    write_summary "CRITICAL" "Unsupported distro"
    exit $EXIT_CRITICAL
fi

SUDO_GROUP=$(get_sudo_group)
log "Package manager: $PKG_MGR, Sudo group: $SUDO_GROUP"

# -----------------------------------------------------------------------------
# PHASE 1: Package Installation
# -----------------------------------------------------------------------------
log ""
log "--- PHASE 1: Package Installation ---"

# Package names can differ slightly
COMMON_PKGS=(rsyslog smartmontools cups openssh-server)
if [[ "$PKG_MGR" == "dnf" ]]; then
    PKGS=("${COMMON_PKGS[@]}" cronie)
else
    PKGS=("${COMMON_PKGS[@]}" cron)
fi

FAILED_PKGS=()
case "$PKG_MGR" in
    dnf)
        log "Updating package cache..."
        dnf makecache >> "$LOG_FILE" 2>&1 || log "Cache update failed, continuing..." "WARN"
        for pkg in "${PKGS[@]}"; do
            log "Installing: $pkg"
            dnf install -y "$pkg" >> "$LOG_FILE" 2>&1 || FAILED_PKGS+=("$pkg")
        done
        ;;
    apt)
        log "Updating package cache..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1 || log "Cache update failed, continuing..." "WARN"
        for pkg in "${PKGS[@]}"; do
            log "Installing: $pkg"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 || FAILED_PKGS+=("$pkg")
        done
        ;;
esac

# -----------------------------------------------------------------------------
# PHASE 2: Service Configuration
# -----------------------------------------------------------------------------
log ""
log "--- PHASE 2: Service Configuration ---"

# Service names
SERVICES=(rsyslog smartmontools cups)
if [[ "$PKG_MGR" == "dnf" ]]; then
    SERVICES+=(cronie sshd)
else
    SERVICES+=(cron ssh)
fi

for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        log "Enabling and starting: $svc"
        systemctl enable "$svc" >> "$LOG_FILE" 2>&1
        systemctl restart "$svc" >> "$LOG_FILE" 2>&1
        if systemctl is-active --quiet "$svc"; then
            log "  $svc: running" "SUCCESS"
        else
            log "  $svc: failed to start" "WARN"
        fi
    else
        log "Service not found: $svc" "WARN"
    fi
done

# -----------------------------------------------------------------------------
# PHASE 3: Firewall Configuration
# -----------------------------------------------------------------------------
log ""
log "--- PHASE 3: Firewall Configuration ---"

if command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-service=ssh >> "$LOG_FILE" 2>&1
        firewall-cmd --permanent --add-port=22/tcp >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        log "firewalld: port 22 allowed" "SUCCESS"
    fi
elif command -v ufw &>/dev/null; then
    ufw allow 22/tcp >> "$LOG_FILE" 2>&1
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >> "$LOG_FILE" 2>&1 || true
    fi
    log "ufw: port 22 allowed" "SUCCESS"
fi

# -----------------------------------------------------------------------------
# PHASE 4: Admin User Creation
# -----------------------------------------------------------------------------
log ""
log "--- PHASE 4: Admin User Configuration ---"

# Sanitize username
TARGET_USER=$(echo "$TARGET_USER" | tr '[:upper:]' '[:lower:]' | tr -d -c 'a-z0-9_-')

if ! id "$TARGET_USER" &>/dev/null; then
    log "Creating user: $TARGET_USER"
    useradd -m -s /bin/bash "$TARGET_USER" >> "$LOG_FILE" 2>&1
fi

echo "${TARGET_USER}:${ADMIN_PASSWORD}" | chpasswd >> "$LOG_FILE" 2>&1
log "Password set for $TARGET_USER to $ADMIN_PASSWORD"

if ! groups "$TARGET_USER" 2>/dev/null | grep -q "\b${SUDO_GROUP}\b"; then
    groupadd "$SUDO_GROUP" 2>/dev/null || true
    usermod -aG "$SUDO_GROUP" "$TARGET_USER" >> "$LOG_FILE" 2>&1
    log "Added $TARGET_USER to $SUDO_GROUP" "SUCCESS"
fi

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
log ""
log "=========================================="
log "INSTALLATION SUMMARY"
log "=========================================="

if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
    log "Failed packages: ${FAILED_PKGS[*]}" "WARN"
    write_summary "WARNING" "N-Sight support installed with failures: ${FAILED_PKGS[*]}"
    exit $EXIT_WARNING
fi

write_summary "OK" "N-Sight support installed, SSH enabled, and user $TARGET_USER configured."
exit $EXIT_SUCCESS
