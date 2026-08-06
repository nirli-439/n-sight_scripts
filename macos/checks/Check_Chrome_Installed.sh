#!/bin/bash
# =============================================================================
# Check_Chrome_Installed.sh - Check if Google Chrome is installed on macOS
# =============================================================================
#
# SYNOPSIS:
#     Checks for Google Chrome installation on macOS and reports:
#     - Installation status (installed/not installed)
#     - Chrome version if installed
#     - Installation path and type (system-wide vs user)
#     - Running status
#
# DESCRIPTION:
#     This monitoring script checks for Chrome installation by:
#     1. Checking /Applications (system-wide installation)
#     2. Checking all user ~/Applications folders
#     3. Reading version info from the app bundle
#     4. Checking if Chrome is currently running
#
#     Designed for N-Sight RMM monitoring checks on macOS.
#     Pair with Install_Chrome_mac.sh for automated remediation.
#
# EXIT CODES:
#     0    = OK (Chrome is installed)
#     1001 = WARNING (Chrome installed but not running)
#     1002 = CRITICAL (Chrome is NOT installed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Chrome_Installed.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Chrome_Installed.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: No special privileges (runs as any user)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Usage:
#     - Deploy as 24x7 Check
#     - Set Install_Chrome_mac.sh as remediation task
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Chrome Installed"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/ChromeCheck_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Chrome application details
readonly APP_NAME="Google Chrome.app"
readonly SYSTEM_INSTALL_PATH="/Applications/${APP_NAME}"
readonly CHROME_BUNDLE_ID="com.google.Chrome"

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

get_chrome_version() {
    local app_path="$1"
    local plist_path="${app_path}/Contents/Info.plist"
    
    if [ -f "$plist_path" ]; then
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

get_chrome_build() {
    local app_path="$1"
    local build
    build=$(defaults read "${app_path}/Contents/Info" CFBundleVersion 2>/dev/null)
    
    if [ -n "$build" ]; then
        echo "$build"
    else
        echo "Unknown"
    fi
}

check_chrome_signed() {
    local app_path="$1"
    
    if codesign -v "$app_path" 2>/dev/null; then
        echo "Valid"
        return 0
    else
        echo "Invalid/Unsigned"
        return 1
    fi
}

check_chrome_running() {
    # Check for Chrome process
    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        return 0
    fi
    
    # Alternative: check for Chrome helper processes
    if pgrep -f "Google Chrome.app" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

find_chrome_installation() {
    # Returns: path to Google Chrome.app if found, empty if not found
    # Sets global variables: CHROME_PATH, CHROME_INSTALL_TYPE
    
    # Check system-wide /Applications first (preferred)
    if [ -d "$SYSTEM_INSTALL_PATH" ]; then
        local bundle_id
        bundle_id=$(defaults read "${SYSTEM_INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
            CHROME_PATH="$SYSTEM_INSTALL_PATH"
            CHROME_INSTALL_TYPE="System-wide (all users)"
            return 0
        fi
    fi
    
    # Check all user home directories
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
                        CHROME_PATH="$user_app_path"
                        CHROME_INSTALL_TYPE="User-level ($(basename "$user_home"))"
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Not found
    CHROME_PATH=""
    CHROME_INSTALL_TYPE=""
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
CHROME_PATH=""
CHROME_INSTALL_TYPE=""
CHROME_VERSION=""
CHROME_BUILD=""
CHROME_SIGNATURE=""
CHROME_RUNNING=false

log "Searching for Google Chrome installation..."

# Find Chrome installation
if find_chrome_installation; then
    CHROME_VERSION=$(get_chrome_version "$CHROME_PATH")
    CHROME_BUILD=$(get_chrome_build "$CHROME_PATH")
    CHROME_SIGNATURE=$(check_chrome_signed "$CHROME_PATH")
    
    log "Google Chrome found!"
    log "Path: $CHROME_PATH"
    log "Install Type: $CHROME_INSTALL_TYPE"
    log "Version: $CHROME_VERSION"
    log "Build: $CHROME_BUILD"
    log "Signature: $CHROME_SIGNATURE"
    
    # Check if Chrome is running
    if check_chrome_running; then
        CHROME_RUNNING=true
        log "Running Status: Running"
    else
        log "Running Status: Not running"
    fi
    
    log ""
    log "=========================================="
    log "Check Results: INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Google Chrome Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    if [ "$CHROME_RUNNING" = true ]; then
        write_summary "OK" "Chrome v${CHROME_VERSION} installed and running"
        echo "Version: $CHROME_VERSION"
        echo "Build: $CHROME_BUILD"
        echo "Path: $CHROME_PATH"
        echo "Install Type: $CHROME_INSTALL_TYPE"
        echo "Signature: $CHROME_SIGNATURE"
        echo "Status: Running"
        
        exit $EXIT_SUCCESS
    else
        write_summary "OK" "Chrome v${CHROME_VERSION} installed (not running)"
        echo "Version: $CHROME_VERSION"
        echo "Build: $CHROME_BUILD"
        echo "Path: $CHROME_PATH"
        echo "Install Type: $CHROME_INSTALL_TYPE"
        echo "Signature: $CHROME_SIGNATURE"
        echo "Status: Not running"
        echo ""
        echo "Note: Chrome is installed but not currently running."
        
        # Return success - installed is what matters for this check
        exit $EXIT_SUCCESS
    fi
else
    log "Google Chrome NOT found in any location" "WARNING"
    log ""
    log "=========================================="
    log "Check Results: NOT INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Google Chrome Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    write_summary "CRITICAL" "Google Chrome is NOT installed"
    echo ""
    echo "Checked locations:"
    echo "  - /Applications/Google Chrome.app (system-wide)"
    echo "  - /Users/*/Applications/Google Chrome.app (per-user)"
    echo ""
    echo "Remediation: Run Install_Chrome_mac.sh to install Chrome for all users"
    
    exit $EXIT_CRITICAL
fi
