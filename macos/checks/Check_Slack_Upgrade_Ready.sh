#!/usr/bin/env bash
# =============================================================================
# Check_Slack_Upgrade_Ready.sh - Check if Slack is ready for automated upgrades
# =============================================================================
#
# SYNOPSIS:
#     Check if Slack can be automatically upgraded on macOS.
#     Designed for deployment via N-Sight RMM.
#
# DESCRIPTION:
#     Verifies that Slack is installed and can be upgraded automatically
#     using the Upgrade_Slack_mac.sh script. Checks version, permissions,
#     and upgrade readiness.
#
# EXIT CODES:
#     0    = OK (Slack ready for upgrade)
#     1001 = Warning (Slack installed but issues detected)
#     1002 = Critical (Slack not installed or cannot be upgraded)
#
# REMEDIATION:
#     Install_Slack_mac.sh - Install or repair Slack installation
#     Upgrade_Slack_mac.sh - Force upgrade to latest version
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Slack_Upgrade_Ready.sh
#     Or:             bash /path/to/Check_Slack_Upgrade_Ready.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Slack_Upgrade_Ready.sh" | sudo bash
#
# NOTES:
#     Author: Nir Livshin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
# N-Sight Monitoring:
#     - Process Check: Slack
#     - OSX Daemon Check: com.tinyspeck.slackmacgap
#     - LaunchAgent Path: /Applications/Slack.app/Contents/Library/LaunchAgents/com.tinyspeck.slackmacgap.Slack.plist
#     - N-Sight Remediation Script: macos/tasks/Upgrade_Slack_mac.sh
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check_Slack_Upgrade_Ready"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/check_$(date +%Y%m%d_%H%M%S).log"
readonly APP_PATH="/Applications/Slack.app"
readonly BUNDLE_ID="com.tinyspeck.slackmacgap"

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

# --- Check if Slack is installed ---
if [[ ! -d "$APP_PATH" ]]; then
    # Check user Applications folders
    for user_home in /Users/*/; do
        [[ "$(basename "$user_home")" == "Shared" ]] && continue
        user_app="${user_home}Applications/Slack.app"
        if [[ -d "$user_app" ]]; then
            user_bundle=$(defaults read "${user_app}/Contents/Info" CFBundleIdentifier 2>/dev/null)
            if [[ "$user_bundle" == "$BUNDLE_ID" || "$user_bundle" == *"slack"* ]]; then
                log "User-level Slack installation found at $user_app" "WARN"
                write_summary "WARNING" "User-level Slack installation found - should be in /Applications"
                exit $EXIT_WARNING
            fi
        fi
    done

    log "Slack is not installed" "ERROR"
    write_summary "CRITICAL" "Slack is not installed - run Install_Slack_mac.sh"
    exit $EXIT_CRITICAL
fi

# --- Verify bundle ID ---
BUNDLE=$(defaults read "${APP_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
if [[ "$BUNDLE" != "$BUNDLE_ID" ]]; then
    log "Slack bundle ID mismatch: $BUNDLE" "ERROR"
    write_summary "CRITICAL" "Slack bundle ID mismatch - $BUNDLE"
    exit $EXIT_CRITICAL
fi

# --- Get current version ---
CURRENT_VER=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
log "Current Slack version: $CURRENT_VER"

# --- Check if Slack binary is accessible ---
if [[ ! -x "${APP_PATH}/Contents/MacOS/Slack" ]]; then
    log "Slack binary is not executable" "ERROR"
    write_summary "CRITICAL" "Slack binary not executable - check permissions"
    exit $EXIT_CRITICAL
fi

# --- Check ownership ---
OWNER=$(stat -f '%Su' "$APP_PATH" 2>/dev/null)
GROUP=$(stat -f '%Sg' "$APP_PATH" 2>/dev/null)
log "Slack ownership: $OWNER:$GROUP"

if [[ "$OWNER" == "root" && "$GROUP" == "wheel" ]]; then
    log "Slack has incorrect ownership - should be user:staff" "WARN"
    write_summary "WARNING" "Slack ownership incorrect - $OWNER:$GROUP"
elif [[ -z "$OWNER" || -z "$GROUP" ]]; then
    log "Could not determine Slack ownership" "WARN"
    write_summary "WARNING" "Could not determine Slack ownership"
fi

# --- Check quarantine attribute ---
if xattr -l "$APP_PATH" 2>/dev/null | grep -q "com.apple.quarantine"; then
    log "Slack has quarantine attribute" "WARN"
    write_summary "WARNING" "Slack has quarantine attribute"
fi

# --- Check if update is needed (by comparing with latest version) ---
# We'll use a temporary file to get the latest version
TMP_DMG="/tmp/Slack_UpdateCheck.dmg"
MOUNT_POINT="/tmp/Slack_Mount"

# Download the latest version DMG
log "Checking for newer Slack version..."
if curl -fL --retry 3 --retry-delay 5 -o "$TMP_DMG" "https://slack.com/ssb/download-osx-universal"; then
    # Mount the DMG
    if hdiutil attach "$TMP_DMG" -nobrowse -quiet -mountpoint "$MOUNT_POINT" 2>/dev/null; then
        # Find the app in DMG
        SRC_APP=$(find "$MOUNT_POINT" -maxdepth 2 -name "Slack.app" -type d 2>/dev/null | head -1)
        if [[ -n "$SRC_APP" ]]; then
            # Get version from DMG
            LATEST_VER=$(defaults read "${SRC_APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
            log "Latest Slack version: $LATEST_VER"

            # Compare versions if both are known
            if [[ "$CURRENT_VER" != "Unknown" && "$LATEST_VER" != "Unknown" ]]; then
                # Parse version numbers for comparison
                IFS='.' read -r current_major current_minor current_patch <<< "$CURRENT_VER"
                IFS='.' read -r latest_major latest_minor latest_patch <<< "$LATEST_VER"

                # Convert to comparable integers
                current_version=$((current_major * 10000 + current_minor * 100 + current_patch))
                latest_version=$((latest_major * 10000 + latest_minor * 100 + latest_patch))

                if [[ $current_version -lt $latest_version ]]; then
                    log "Newer version available: v${CURRENT_VER} → v${LATEST_VER}" "WARN"
                    write_summary "WARNING" "Slack update available: v${CURRENT_VER} → v${LATEST_VER}"
                    # Cleanup and exit with warning
                    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
                    rm -f "$TMP_DMG" 2>/dev/null || true
                    exit $EXIT_WARNING
                elif [[ $current_version -gt $latest_version ]]; then
                    log "Installed version is newer than available: v${CURRENT_VER} > v${LATEST_VER}" "WARN"
                    write_summary "WARNING" "Installed Slack version newer than available"
                else
                    log "Slack is up to date (v${CURRENT_VER})" "SUCCESS"
                fi
            else
                log "Could not compare versions: current=$CURRENT_VER, latest=$LATEST_VER" "INFO"
            fi
        else
            log "Slack.app not found in downloaded DMG" "WARN"
        fi

        # Unmount DMG
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    else
        log "Failed to mount DMG for version check" "WARN"
    fi

    # Cleanup DMG file
    rm -f "$TMP_DMG" 2>/dev/null || true
else
    log "Failed to download latest Slack version for comparison" "WARN"
fi

# --- All checks passed ---
log "Slack is ready for use and current" "SUCCESS"
write_summary "OK" "Slack v${CURRENT_VER} installed and ready for automated upgrades"
exit $EXIT_SUCCESS
