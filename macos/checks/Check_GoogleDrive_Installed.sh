#!/bin/bash
# =============================================================================
# Check_GoogleDrive_Installed.sh - Check if Google Drive is installed on macOS
# =============================================================================
#
# SYNOPSIS:
#   Checks for Google Drive installation on macOS and reports:
#   - Installation status (installed/not installed)
#   - Google Drive version and path if installed
#   Adds Google Drive to Login Items so it starts at login (when installed).
#
# DESCRIPTION:
#   This monitoring script checks for Google Drive installation by:
#   1. Checking /Applications (system-wide installation)
#   2. Checking ALL user ~/Applications folders
#   3. Reading version info from the app bundle
#   4. When installed: adds Google Drive to Login Items for the console user
#   
#   Designed for N-Sight RMM monitoring checks on macOS.
#
# EXIT CODES:
#   0    = OK (Google Drive is installed)
#   1002 = CRITICAL (Google Drive is NOT installed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_GoogleDrive_Installed.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_GoogleDrive_Installed.sh" | sudo bash
#
# NOTES:
#   Author: IT Admin
#   Version: 1.2
#   Requires: No special privileges for check; adding Login Item runs as console user
#   Platform: macOS 10.15+ (Catalina and later)
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Google Drive Installed"
readonly SCRIPT_VERSION="1.2"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/GoogleDriveCheck_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Google Drive application details
readonly APP_NAME="Google Drive.app"
readonly SYSTEM_INSTALL_PATH="/Applications/${APP_NAME}"

# Bundle identifier for Google Drive
readonly GOOGLEDRIVE_BUNDLE_ID="com.google.drivefs"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    echo "$message" | tee -a "$LOG_FILE" 2>/dev/null
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

get_macos_name() {
    sw_vers -productName 2>/dev/null || echo "macOS"
}

get_google_drive_app_version() {
    local app_path="$1"
    local plist_path="${app_path}/Contents/Info.plist"
    
    if [ -f "$plist_path" ]; then
        # Use defaults to read the version from Info.plist
        local version
        version=$(defaults read "${app_path}/Contents/Info" CFBundleShortVersionString 2>/dev/null)
        
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
        
        # Fallback: try using PlistBuddy
        if [ -x /usr/libexec/PlistBuddy ]; then
            version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path" 2>/dev/null)
            if [ -n "$version" ]; then
                echo "$version"
                return 0
            fi
        fi
    fi
    
    echo "Unknown"
    return 1
}

get_googledrive_build() {
    local app_path="$1"
    
    # Get the build/bundle version
    local build
    build=$(defaults read "${app_path}/Contents/Info" CFBundleVersion 2>/dev/null)
    
    if [ -n "$build" ]; then
        echo "$build"
    else
        echo "Unknown"
    fi
}

check_googledrive_signed() {
    local app_path="$1"
    
    # Verify code signature
    if codesign -v "$app_path" 2>/dev/null; then
        echo "Valid"
        return 0
    else
        echo "Invalid/Unsigned"
        return 1
    fi
}

add_googledrive_to_login_items() {
    # Add Google Drive to Login Items for the console user so it starts at login.
    local app_path="$1"
    local console_user=""
    local run_as=""
    
    [ ! -d "$app_path" ] && return 1
    
    # Get the currently logged-in user and how to run osascript as that user
    if [ "$(whoami)" = "root" ]; then
        console_user=$(stat -f '%Su' /dev/console 2>/dev/null)
        [ -z "$console_user" ] && console_user=$(ls -la /dev/console 2>/dev/null | awk '{print $3}')
        [ -n "$console_user" ] && run_as="sudo -u $console_user"
    else
        console_user=$(whoami)
        run_as=""
    fi
    
    [ -z "$console_user" ] && return 1
    
    # Check if already in Login Items (avoid duplicate)
    local already_added
    already_added=$($run_as osascript -e "
        tell application \"System Events\"
            get name of every login item
        end tell
    " 2>/dev/null | grep -i "Google Drive")
    
    if [ -n "$already_added" ]; then
        log "Google Drive already in Login Items for $console_user"
        return 0
    fi
    
    # Add to Login Items
    if $run_as osascript -e "
        tell application \"System Events\"
            make login item at end with properties {path:\"$app_path\", hidden:false}
        end tell
    " 2>/dev/null; then
        log "Added Google Drive to Login Items for $console_user (starts at login)"
        return 0
    else
        log "Could not add Google Drive to Login Items (user may need to allow in Privacy)" "WARNING"
        return 1
    fi
}

find_googledrive_installation() {
    # Check system-wide /Applications first (preferred)
    if [ -d "$SYSTEM_INSTALL_PATH" ]; then
        local bundle_id
        bundle_id=$(defaults read "${SYSTEM_INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$GOOGLEDRIVE_BUNDLE_ID" ] || [[ "$bundle_id" == *"google"*"drive"* ]]; then
            GOOGLEDRIVE_PATH="$SYSTEM_INSTALL_PATH"
            GOOGLEDRIVE_INSTALL_TYPE="System-wide (all users)"
            return 0
        fi
    fi
    
    # Check ALL user home directories
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$GOOGLEDRIVE_BUNDLE_ID" ] || [[ "$bundle_id" == *"google"*"drive"* ]]; then
                        GOOGLEDRIVE_PATH="$user_app_path"
                        GOOGLEDRIVE_INSTALL_TYPE="User-level ($(basename "$user_home"))"
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Not found
    GOOGLEDRIVE_PATH=""
    GOOGLEDRIVE_INSTALL_TYPE=""
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

# Ensure log directory exists (may fail without root, that's OK)
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "macOS: $(get_macos_name) $(get_macos_version)"
log "Build: $(sw_vers -buildVersion 2>/dev/null || echo 'Unknown')"
log "Architecture: $(uname -m)"
log "Check Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Running as: $(whoami)"
log ""

# Initialize variables
GOOGLEDRIVE_PATH=""
GOOGLEDRIVE_INSTALL_TYPE=""
GOOGLEDRIVE_VERSION=""
GOOGLEDRIVE_BUILD=""
GOOGLEDRIVE_SIGNATURE=""
log "Searching for Google Drive installation..."

# Find Google Drive installation
if find_googledrive_installation; then
    GOOGLEDRIVE_VERSION=$(get_google_drive_app_version "$GOOGLEDRIVE_PATH")
    GOOGLEDRIVE_BUILD=$(get_googledrive_build "$GOOGLEDRIVE_PATH")
    GOOGLEDRIVE_SIGNATURE=$(check_googledrive_signed "$GOOGLEDRIVE_PATH")
    
    log "Google Drive found at: $GOOGLEDRIVE_PATH"
    log "Version: $GOOGLEDRIVE_VERSION | Build: $GOOGLEDRIVE_BUILD | Signature: $GOOGLEDRIVE_SIGNATURE"
    
    # Add to Login Items so it starts at login (for console user)
    add_googledrive_to_login_items "$GOOGLEDRIVE_PATH" || true
    
    log ""
    log "=========================================="
    log "Check Results: INSTALLED"
    log "=========================================="
    
    # Output results (installation only)
    echo ""
    echo "=========================================="
    echo "Google Drive Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    write_summary "OK" "Google Drive v${GOOGLEDRIVE_VERSION} installed"
    echo "Version: $GOOGLEDRIVE_VERSION"
    echo "Build: $GOOGLEDRIVE_BUILD"
    echo "Path: $GOOGLEDRIVE_PATH"
    echo "Install Type: $GOOGLEDRIVE_INSTALL_TYPE"
    echo "Signature: $GOOGLEDRIVE_SIGNATURE"
    echo "Login Items: Google Drive added to start at login (if not already)"
    
    exit $EXIT_SUCCESS
else
    log "Google Drive NOT found in any location" "WARNING"
    log ""
    log "=========================================="
    log "Check Results: NOT INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Google Drive Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    write_summary "CRITICAL" "Google Drive is NOT installed"
    echo ""
    echo "Checked locations:"
    echo "  - /Applications/Google Drive.app (system-wide)"
    echo "  - /Users/*/Applications/Google Drive.app (per-user)"
    echo ""
    echo "To install Google Drive, download from: https://www.google.com/drive/download/"
    
    exit $EXIT_CRITICAL
fi
