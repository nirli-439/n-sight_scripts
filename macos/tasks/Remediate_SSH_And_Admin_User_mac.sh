#!/usr/bin/env bash
# =============================================================================
# Remediate_SSH_And_Admin_User_mac.sh - Enable SSH and create admin user
# =============================================================================
#
# SYNOPSIS:
#     Enable Remote Login (SSH), create a user with password "1111",
#     and add the user to the admin group (sudo rights).
#
# DESCRIPTION:
#     - Enables Remote Login (SSH) via systemsetup or launchctl
#     - Allows SSH in Application Firewall if enabled
#     - Creates a local user if not present (username from argument)
#     - Sets user password to "1111" (macOS requires min 4 characters)
#     - Adds user to admin group for sudo rights
#
# USAGE:
#     sudo ./Remediate_SSH_And_Admin_User_mac.sh [USERNAME]
#     Default username: admin (or pass as first argument in N-Sight)
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning (e.g. user already existed, SSH already enabled)
#     1002 = Critical/Error
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Remediate_SSH_And_Admin_User_mac.sh [USERNAME]
#     Or:             bash /path/to/Remediate_SSH_And_Admin_User_mac.sh [USERNAME]   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Remediate_SSH_And_Admin_User_mac.sh" | sudo bash -s [USERNAME]
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges
#     Platform: macOS 10.15+
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="SSH and Admin User (macOS)"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/ssh_admin_user_mac_$(date +%Y%m%d_%H%M%S).log"
readonly ADMIN_PASSWORD="1111"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Username: first argument or default "admin"
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
log "Target user: $TARGET_USER"
log "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
log "Log: $LOG_FILE"
log ""

check_root

# Sanitize username: lowercase, alphanumeric and underscores only
TARGET_USER=$(echo "$TARGET_USER" | tr '[:upper:]' '[:lower:]' | tr -d -c 'a-z0-9_-')
if [[ -z "$TARGET_USER" ]]; then
    log "Invalid or empty username (use alphanumeric, underscore, hyphen)" "ERROR"
    write_summary "CRITICAL" "Invalid username"
    exit $EXIT_CRITICAL
fi

# -----------------------------------------------------------------------------
# 1. Enable Remote Login (SSH)
# -----------------------------------------------------------------------------
log ""
log "--- Remote Login (SSH) ---"

REMOTE_LOGIN_WAS_ON=0
if systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
    log "Remote Login already enabled"
    REMOTE_LOGIN_WAS_ON=1
else
    if systemsetup -setremotelogin on >> "$LOG_FILE" 2>&1; then
        log "Remote Login enabled via systemsetup" "SUCCESS"
    else
        # Fallback: load SSH launchd daemon (e.g. Catalina+ when GUI is stuck)
        for plist in /System/Library/LaunchDaemons/com.openssh.sshd.plist /System/Library/LaunchDaemons/ssh.plist; do
            if [[ -f "$plist" ]]; then
                launchctl load -w "$plist" >> "$LOG_FILE" 2>&1
                log "Remote Login enabled via launchctl: $plist" "SUCCESS"
                break
            fi
        done
    fi
fi

# -----------------------------------------------------------------------------
# 1b. Allow SSH in Application Firewall (if firewall is on)
# -----------------------------------------------------------------------------
log ""
log "--- Application Firewall ---"
if [[ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]]; then
    FW_STATE=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
    if echo "$FW_STATE" | grep -q "enabled"; then
        # Allow sshd so SSH works when firewall is on
        if [[ -f /usr/sbin/sshd ]]; then
            /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd >> "$LOG_FILE" 2>&1 || true
        fi
        if [[ -f /usr/libexec/sshd-keygen-wrapper ]]; then
            /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/sshd-keygen-wrapper >> "$LOG_FILE" 2>&1 || true
        fi
        log "Firewall: SSH (sshd) allowed" "SUCCESS"
    else
        log "Application Firewall not enabled, skipping" "INFO"
    fi
else
    log "Application Firewall not found, skipping" "INFO"
fi

# -----------------------------------------------------------------------------
# 2. Create user with password "1" and add to admin group
# -----------------------------------------------------------------------------
log ""
log "--- User: $TARGET_USER ---"

USER_EXISTED=0
if id "$TARGET_USER" &>/dev/null; then
    log "User $TARGET_USER already exists"
    USER_EXISTED=1
    # Set password to "1" (idempotent)
    if dscl . -passwd "/Users/$TARGET_USER" "$ADMIN_PASSWORD" >> "$LOG_FILE" 2>&1; then
        log "Password set for $TARGET_USER"
    else
        log "Failed to set password for $TARGET_USER (may need sysadminctl -resetPassword)" "WARN"
    fi
else
    # Create user with sysadminctl (modern macOS)
    if sysadminctl -addUser "$TARGET_USER" -password "$ADMIN_PASSWORD" -fullName "$TARGET_USER" >> "$LOG_FILE" 2>&1; then
        log "Created user $TARGET_USER" "SUCCESS"
    else
        log "Failed to create user $TARGET_USER" "ERROR"
        write_summary "CRITICAL" "User creation failed"
        exit $EXIT_CRITICAL
    fi
fi

# Add user to admin group (sudo rights)
if dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -q "\b${TARGET_USER}\b"; then
    log "User $TARGET_USER already in admin group"
else
    if dscl . -append /Groups/admin GroupMembership "$TARGET_USER" >> "$LOG_FILE" 2>&1; then
        log "Added $TARGET_USER to admin group" "SUCCESS"
    else
        log "Failed to add $TARGET_USER to admin group" "ERROR"
        write_summary "CRITICAL" "Failed to add user to admin group"
        exit $EXIT_CRITICAL
    fi
fi

# -----------------------------------------------------------------------------
# Verify port 22 is listening
# -----------------------------------------------------------------------------
if netstat -an -p tcp 2>/dev/null | grep -q '\.22.*LISTEN'; then
    log "Port 22 is listening (SSH reachable)" "SUCCESS"
else
    log "Port 22 not yet listening; Remote Login may need a moment" "WARN"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log ""
log "=========================================="
log "Script completed successfully" "SUCCESS"

if [[ $USER_EXISTED -eq 1 ]]; then
    write_summary "OK" "SSH enabled; user $TARGET_USER already existed, password and admin group updated"
else
    write_summary "OK" "SSH enabled; user $TARGET_USER created with password '1111' and admin (sudo) rights"
fi
log "Connect with: ssh ${TARGET_USER}@<this-mac-ip> (password: ${ADMIN_PASSWORD})"
exit $EXIT_SUCCESS
