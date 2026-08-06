#!/usr/bin/env bash
# =============================================================================
# Check_AppleID_Status.sh - Check Apple ID login and Find My status on macOS
# =============================================================================
#
# SYNOPSIS:
#     Check if Apple ID is logged in and Find My is active on macOS.
#     Designed for deployment via N-Sight RMM.
#
# DESCRIPTION:
#     This script checks the Apple ID login status and Find My device activation
#     on macOS. It verifies both user-level Apple ID login and system-level
#     Find My Mac status.
#
# EXIT CODES:
#     0    = OK (Apple ID logged in and Find My active)
#     1001 = Warning (Apple ID logged in but Find My not active)
#     1002 = Critical (Apple ID not logged in or major issues)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_AppleID_Status.sh
#     Or:             bash /path/to/Check_AppleID_Status.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_AppleID_Status.sh" | sudo bash
#
# NOTES:
#     Author: Nir Livshin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
# N-Sight Monitoring:
#     - Process Check: none
#     - OSX Daemon Check: none
#     - LaunchAgent Path: none
#     - LaunchDaemon Path: /Library/LaunchDaemons/com.apple.findmymac.plist
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check_AppleID_Status"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/check_$(date +%Y%m%d_%H%M%S).log"
readonly FINDMY_PLIST="/Library/Preferences/com.apple.FindMyMac.plist"

# Exit codes for N-Sight
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

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# --- Check Find My Mac status ---
if [[ -f "$FINDMY_PLIST" ]]; then
    FMM_ENABLED=$(defaults read "$FINDMY_PLIST" FMMEnabled 2>/dev/null)
    if [[ "$FMM_ENABLED" -eq 1 ]]; then
        log "Find My Mac is ACTIVE"
        FMM_ACTIVE=true
    else
        log "Find My Mac is NOT active"
        FMM_ACTIVE=false
    fi
else
    log "Find My Mac preferences not found" "WARN"
    FMM_ACTIVE=false
fi

# --- Check Apple ID login status ---
# We'll check for the presence of an Apple ID in the keychain
if security find-generic-password -la AppleID 2>/dev/null | grep -q "AppleID"; then
    log "Apple ID is logged in"
    APPLE_ID_LOGGED_IN=true
else
    log "No Apple ID found in keychain" "ERROR"
    APPLE_ID_LOGGED_IN=false
fi

# --- Check User account Apple ID ---
# Check for Apple ID in user preferences
APPLE_ID_PREFERENCES=$(defaults read /Users/$USER/Library/Preferences/com.apple.appleaccount MigratedAccounts 2>/dev/null || echo "")

if [[ -n "$APPLE_ID_PREFERENCES" || "$APPLE_ID_LOGGED_IN" == true ]]; then
    log "User Apple Account: Configured"

    # Extract Apple ID if possible
    if [[ -n "$APPLE_ID_PREFERENCES" ]]; then
        # Use sed to extract email from the preference output
        USER_APPLE_ID=$(echo "$APPLE_ID_PREFERENCES" | grep -o '[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]{2,}' | head -1)
        if [[ -n "$USER_APPLE_ID" ]]; then
            log "Apple ID: $USER_APPLE_ID"
            # Mask part of the email for security
            DISPLAY_APPLE_ID="$(echo "$USER_APPLE_ID" | sed 's/\([^@]\{2\}\)[^@]*@/\1***@/')"
        fi
    fi
else
    log "User Apple Account: Not configured" "ERROR"
fi

# --- Output results and determine status ---
if [[ "$APPLE_ID_LOGGED_IN" == true ]]; then
    if [[ "$FMM_ACTIVE" == true ]]; then
        log "Both Apple ID and Find My are active" "SUCCESS"
        write_summary "OK" "Apple ID logged in and Find My active"
        exit $EXIT_SUCCESS
    else
        log "Apple ID logged in but Find My not active" "WARN"
        write_summary "WARNING" "Apple ID logged in but Find My disabled"
        exit $EXIT_WARNING
    fi
else
    log "Apple ID not logged in" "ERROR"
    write_summary "CRITICAL" "Apple ID not logged in"
    exit $EXIT_CRITICAL
fi
