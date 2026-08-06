#!/usr/bin/env bash
# =============================================================================
# Check_Desktop_Environment.sh - Desktop environment detection for N-Sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Detect and report the desktop environment (DE) on the system.
#
# DESCRIPTION:
#     This monitoring script identifies the desktop environment for inventory
#     and compliance. Detection order:
#     1. Active graphical session (loginctl / session type)
#     2. Default session from AccountsService (GDM/sddm)
#     3. Installed DE packages (gnome-session, plasma-desktop, xfce4-session, etc.)
#
#     Supports Fedora (dnf/rpm) and Ubuntu (dpkg/apt). Assumes GNOME is common;
#     also detects KDE, XFCE, MATE.
#
# EXIT CODES:
#     0    = Success (DE detected)
#     1001 = Warning (unknown or no DE detected)
#     1002 = Critical (root required or script error)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Desktop_Environment.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/checks/Check_Desktop_Environment.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, Ubuntu 22.04+ (universal; GNOME assumed common)
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Desktop Environment"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/de_check_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

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

# Detect package manager (Fedora = dnf, Ubuntu = apt)
get_pkg_mgr() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    else
        echo ""
    fi
}

# Detect DE from active graphical session (loginctl)
detect_from_session() {
    local de=""
    if ! command -v loginctl &>/dev/null; then
        return 1
    fi
    local session_id
    session_id=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "$session_id" ]] && return 1
    local session_type
    session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null)
    [[ "$session_type" != "x11" && "$session_type" != "wayland" ]] && return 1
    local desktop
    desktop=$(loginctl show-session "$session_id" -p Desktop --value 2>/dev/null)
    case "${desktop,,}" in
        gnome|gnome-xorg|gnome-wayland)  echo "GNOME"; return 0 ;;
        kde|plasma)                       echo "KDE";   return 0 ;;
        xfce)                             echo "XFCE";  return 0 ;;
        mate)                             echo "MATE";  return 0 ;;
        *)                                echo "";     return 1 ;;
    esac
}

# Detect default session from AccountsService (GDM/sddm user config)
detect_from_accounts_service() {
    local accounts_dir="/var/lib/AccountsService/users"
    [[ ! -d "$accounts_dir" ]] && return 1
    local session_file
    for session_file in "$accounts_dir"/*; do
        [[ -f "$session_file" ]] || continue
        local session
        session=$(grep -E "^Session=" "$session_file" 2>/dev/null | cut -d= -f2-)
        [[ -z "$session" ]] && continue
        session="${session,,}"
        if [[ "$session" == *gnome* ]]; then echo "GNOME"; return 0; fi
        if [[ "$session" == *plasma* || "$session" == *kde* ]]; then echo "KDE"; return 0; fi
        if [[ "$session" == *xfce* ]]; then echo "XFCE"; return 0; fi
        if [[ "$session" == *mate* ]]; then echo "MATE"; return 0; fi
    done
    return 1
}

# Detect DE from installed packages (Fedora + Ubuntu)
detect_from_packages() {
    local pkg_mgr
    pkg_mgr=$(get_pkg_mgr)
    case "$pkg_mgr" in
        dnf)
            rpm -q gnome-session &>/dev/null       && { echo "GNOME"; return 0; }
            rpm -q plasma-desktop &>/dev/null      && { echo "KDE";   return 0; }
            rpm -q xfce4-session &>/dev/null      && { echo "XFCE";  return 0; }
            rpm -q mate-session-manager &>/dev/null && { echo "MATE";  return 0; }
            ;;
        apt)
            dpkg -l gnome-session 2>/dev/null | grep -q "^ii" && { echo "GNOME"; return 0; }
            dpkg -l plasma-desktop 2>/dev/null | grep -q "^ii" && { echo "KDE";   return 0; }
            dpkg -l xfce4-session 2>/dev/null | grep -q "^ii" && { echo "XFCE";  return 0; }
            dpkg -l mate-session-manager 2>/dev/null | grep -q "^ii" && { echo "MATE";  return 0; }
            ;;
        *) return 1 ;;
    esac
    return 1
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
log "Distro: $(source /etc/os-release 2>/dev/null && echo "${NAME:-Unknown} ${VERSION_ID:-}" || echo "Unknown")"
log "Log: $LOG_FILE"
log ""

check_root

DE=""
# 1. Try active session
DE=$(detect_from_session 2>/dev/null) || true
[[ -n "$DE" ]] && DE="${DE//[$'\r\n']}"
# 2. Try default session (AccountsService)
if [[ -z "$DE" ]]; then
    DE=$(detect_from_accounts_service 2>/dev/null) || true
    [[ -n "$DE" ]] && DE="${DE//[$'\r\n']}"
fi
# 3. Fallback: installed packages
if [[ -z "$DE" ]]; then
    DE=$(detect_from_packages 2>/dev/null) || true
    [[ -n "$DE" ]] && DE="${DE//[$'\r\n']}"
fi

if [[ -n "$DE" ]]; then
    log "Desktop environment detected: $DE" "SUCCESS"
    write_summary "OK" "Desktop environment: $DE"
    exit $EXIT_SUCCESS
else
    log "No known desktop environment detected (GNOME/KDE/XFCE/MATE)" "WARN"
    write_summary "WARNING" "Desktop environment: unknown or none"
    exit $EXIT_WARNING
fi
