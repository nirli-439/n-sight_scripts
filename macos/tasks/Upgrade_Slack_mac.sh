#!/usr/bin/env bash
# =============================================================================
# Upgrade_Slack_mac.sh - Automatically upgrade Slack for macOS without user interaction
# =============================================================================
#
# SYNOPSIS:
#     Upgrade Slack to the latest version on macOS without user interaction.
#     Designed for deployment via N-Sight RMM.
#
# DESCRIPTION:
#     Downloads and installs the latest version of Slack macOS app from the official
#     universal download URL. Replaces existing installation in /Applications.
#     Handles both fresh install and upgrade scenarios.
#
# EXIT CODES:
#     0    = Success (PASS)
#     1001 = Warning
#     1002 = Critical/Error
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Upgrade_Slack_mac.sh
#     Or:             bash /path/to/Upgrade_Slack_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Upgrade_Slack_mac.sh" | sudo bash
#
# NOTES:
#     Author: Nir Livshin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#     Source: https://slack.com/ssb/download-osx-universal
#
# N-Sight Monitoring:
#     - Process Check: Slack
#     - OSX Daemon Check: com.tinyspeck.slackmacgap
#     - LaunchAgent Path: /Applications/Slack.app/Contents/Library/LaunchAgents/com.tinyspeck.slackmacgap.Slack.plist
#     - N-Sight Check Script: macos/checks/Check_Slack_Installed.sh
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Upgrade_Slack_mac"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/script_$(date +%Y%m%d_%H%M%S).log"

readonly SLACK_URL="https://slack.com/ssb/download-osx-universal"
readonly DMG="/tmp/Slack.dmg"
readonly MOUNT="/Volumes/Slack"
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

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -f "$DMG" 2>/dev/null || true
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
log "macOS: $(get_macos_version)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# Set trap for cleanup
trap cleanup EXIT

# --- Check if Slack is already installed ---
if [[ -d "$APP_PATH" ]]; then
    CURRENT_VER=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    log "Current Slack version: $CURRENT_VER"

    # Verify bundle ID
    BUNDLE=$(defaults read "${APP_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
    if [[ "$BUNDLE" != "$BUNDLE_ID" && "$BUNDLE" != *"slack"* ]]; then
        log "Found app at $APP_PATH but bundle ID ($BUNDLE) doesn't match expected Slack app" "ERROR"
        write_summary "CRITICAL" "Slack installation corrupt - bundle ID mismatch"
        exit $EXIT_CRITICAL
    fi

    FRESH_INSTALL=false
else
    log "Slack not found at $APP_PATH - installing fresh copy"
    FRESH_INSTALL=true
fi

# --- Download latest version ---
log "Downloading latest Slack from $SLACK_URL..."
if ! curl -fL --retry 3 --retry-delay 5 -o "$DMG" "$SLACK_URL"; then
    log "Failed to download Slack DMG" "ERROR"
    write_summary "CRITICAL" "Failed to download Slack installer"
    exit $EXIT_CRITICAL
fi

# Verify DMG was downloaded
if [[ ! -f "$DMG" ]]; then
    log "DMG file not found after download" "ERROR"
    write_summary "CRITICAL" "Slack installer download failed"
    exit $EXIT_CRITICAL
fi

log "Successfully downloaded Slack DMG: $(du -h "$DMG" | cut -f1)"

# --- Mount DMG ---
log "Mounting Slack DMG..."
if ! hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT" 2>/dev/null; then
    log "Failed to mount Slack DMG" "ERROR"
    write_summary "CRITICAL" "Failed to mount Slack installer"
    exit $EXIT_CRITICAL
fi

# Find source app in DMG
SRC_APP=$(find /Volumes -maxdepth 2 -name "Slack.app" -type d 2>/dev/null | head -1)
if [[ -z "$SRC_APP" ]]; then
    log "Slack.app not found on mounted DMG" "ERROR"
    write_summary "CRITICAL" "Slack app not found in installer"
    exit $EXIT_CRITICAL
fi

log "Found Slack.app at: $SRC_APP"

# Get version of new installation
NEW_VER=$(defaults read "${SRC_APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
log "New Slack version: $NEW_VER"

# Compare versions if upgrading
if [[ "$FRESH_INSTALL" == false && "$CURRENT_VER" == "$NEW_VER" ]]; then
    if [[ -x "${APP_PATH}/Contents/MacOS/Slack" ]]; then
        log "Slack is already up to date (v${CURRENT_VER})"
        write_summary "OK" "Slack v${CURRENT_VER} already installed and current"
        exit $EXIT_SUCCESS
    else
        log "Slack binary appears corrupted - reinstalling same version"
    fi
fi

# --- Install/Upgrade ---
log "Installing/upgrading Slack to /Applications..."

# Remove existing installation if it exists
if [[ -d "$APP_PATH" ]]; then
    log "Removing existing Slack installation..."
    rm -rf "$APP_PATH" 2>/dev/null || {
        log "Failed to remove existing Slack installation" "ERROR"
        write_summary "CRITICAL" "Cannot remove existing Slack installation"
        exit $EXIT_CRITICAL
    }
fi

# Copy new version
if ! cp -R "$SRC_APP" /Applications/; then
    log "Failed to copy Slack.app to /Applications" "ERROR"
    write_summary "CRITICAL" "Failed to install Slack"
    exit $EXIT_CRITICAL
fi

log "Slack.app copied to /Applications"

# Set appropriate ownership
OWNER=$(stat -f '%Su' /dev/console 2>/dev/null)
if [[ -n "$OWNER" && "$OWNER" != "root" ]]; then
    chown -R "${OWNER}:staff" "$APP_PATH" 2>/dev/null || true
    log "Ownership set to ${OWNER}:staff"
else
    chown -R root:wheel "$APP_PATH" 2>/dev/null || true
    log "Ownership set to root:wheel"
fi

# Remove quarantine attribute
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

# Set proper permissions
chmod -R 755 "$APP_PATH" 2>/dev/null || true
log "Permissions configured"

# --- Verify installation ---
if [[ ! -d "$APP_PATH" ]]; then
    log "Slack installation failed - $APP_PATH not found" "ERROR"
    write_summary "CRITICAL" "Slack installation failed"
    exit $EXIT_CRITICAL
fi

# Verify bundle identifier
BUNDLE=$(defaults read "${APP_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
if [[ "$BUNDLE" != "$BUNDLE_ID" ]]; then
    log "Bundle ID mismatch after install: $BUNDLE" "ERROR"
    write_summary "CRITICAL" "Bundle ID mismatch after install"
    exit $EXIT_CRITICAL
fi

# Get final version
FINAL_VER=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")

# --- Success output ---
log "Slack installation/upgrade completed successfully"

if [[ "$FRESH_INSTALL" == true ]]; then
    log "Fresh installation: v${FINAL_VER}" "SUCCESS"
    write_summary "OK" "Slack v${FINAL_VER} installed successfully"
else
    log "Upgrade completed: v${CURRENT_VER} → v${FINAL_VER}" "SUCCESS"
    write_summary "OK" "Slack upgraded from v${CURRENT_VER} to v${FINAL_VER}"
fi

exit $EXIT_SUCCESS
