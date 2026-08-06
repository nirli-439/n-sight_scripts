#!/bin/bash
# =============================================================================
# Check_Twingate_Installed.sh - Check if Twingate is installed on macOS
# =============================================================================
#
# SYNOPSIS:
#   Checks for Twingate installation on macOS and reports:
#   - Installation status (installed/not installed)
#   - Twingate version if installed
#   - Installation path and type (system-wide vs user)
#   - Running status
#
# DESCRIPTION:
#   This monitoring script checks for Twingate installation by:
#   1. Checking /Applications (system-wide installation)
#   2. Checking ALL user ~/Applications folders
#   3. Reading version info from the app bundle
#   4. Checking if Twingate is currently running
#   
#   Designed for N-Sight RMM monitoring checks on macOS.
#
# EXIT CODES:
#   0    = OK (Twingate is installed)
#   1001 = WARNING (Twingate is installed but not running)
#   1002 = CRITICAL (Twingate is NOT installed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Twingate_Installed.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Twingate_Installed.sh" | sudo bash
#
# NOTES:
#   Author: IT Admin
#   Version: 1.1
#   Requires: No special privileges (runs as any user)
#   Platform: macOS 10.15+ (Catalina and later)
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Twingate Installed"
readonly SCRIPT_VERSION="1.1"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/TwingateCheck_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Twingate application details
readonly APP_NAME="Twingate.app"
readonly SYSTEM_INSTALL_PATH="/Applications/${APP_NAME}"
readonly TWINGATE_BUNDLE_ID="com.twingate.macos"

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

get_twingate_version() {
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

get_twingate_build() {
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

check_twingate_signed() {
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

check_twingate_running() {
    # Check for Twingate process
    if pgrep -x "Twingate" >/dev/null 2>&1; then
        return 0
    fi
    
    # Alternative: check for Twingate helper processes
    if pgrep -f "Twingate" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

check_system_extension() {
    # Check if Twingate System Extension is loaded (for VPN functionality)
    local extension_status
    extension_status=$(systemextensionsctl list 2>/dev/null | grep -i "twingate" || echo "")
    
    if [ -n "$extension_status" ]; then
        echo "$extension_status"
        return 0
    else
        echo "Not loaded"
        return 1
    fi
}

find_twingate_installation() {
    # Check system-wide /Applications first (preferred)
    if [ -d "$SYSTEM_INSTALL_PATH" ]; then
        local bundle_id
        bundle_id=$(defaults read "${SYSTEM_INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$TWINGATE_BUNDLE_ID" ] || [[ "$bundle_id" == *"twingate"* ]]; then
            TWINGATE_PATH="$SYSTEM_INSTALL_PATH"
            TWINGATE_INSTALL_TYPE="System-wide (all users)"
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
                    
                    if [ "$bundle_id" = "$TWINGATE_BUNDLE_ID" ] || [[ "$bundle_id" == *"twingate"* ]]; then
                        TWINGATE_PATH="$user_app_path"
                        TWINGATE_INSTALL_TYPE="User-level ($(basename "$user_home"))"
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Not found
    TWINGATE_PATH=""
    TWINGATE_INSTALL_TYPE=""
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
TWINGATE_PATH=""
TWINGATE_INSTALL_TYPE=""
TWINGATE_VERSION=""
TWINGATE_BUILD=""
TWINGATE_SIGNATURE=""
TWINGATE_RUNNING=false

log "Searching for Twingate installation..."

# Find Twingate installation
if find_twingate_installation; then
    TWINGATE_VERSION=$(get_twingate_version "$TWINGATE_PATH")
    TWINGATE_BUILD=$(get_twingate_build "$TWINGATE_PATH")
    TWINGATE_SIGNATURE=$(check_twingate_signed "$TWINGATE_PATH")
    
    log "Twingate found!"
    log "Path: $TWINGATE_PATH"
    log "Install Type: $TWINGATE_INSTALL_TYPE"
    log "Version: $TWINGATE_VERSION"
    log "Build: $TWINGATE_BUILD"
    log "Signature: $TWINGATE_SIGNATURE"
    
    # Check if Twingate is running
    if check_twingate_running; then
        TWINGATE_RUNNING=true
        log "Running Status: Running"
    else
        log "Running Status: Not running"
    fi
    
    # Check System Extension status
    SYSTEM_EXT_STATUS=$(check_system_extension)
    log "System Extension: $SYSTEM_EXT_STATUS"
    
    log ""
    log "=========================================="
    log "Check Results: INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Twingate Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    if [ "$TWINGATE_RUNNING" = true ]; then
        write_summary "OK" "Twingate v${TWINGATE_VERSION} installed and running"
        echo "Version: $TWINGATE_VERSION"
        echo "Build: $TWINGATE_BUILD"
        echo "Path: $TWINGATE_PATH"
        echo "Install Type: $TWINGATE_INSTALL_TYPE"
        echo "Signature: $TWINGATE_SIGNATURE"
        echo "Status: Running"
        echo "System Extension: $SYSTEM_EXT_STATUS"
        
        exit $EXIT_SUCCESS
    else
        write_summary "OK" "Twingate v${TWINGATE_VERSION} installed (not running)"
        echo "Version: $TWINGATE_VERSION"
        echo "Build: $TWINGATE_BUILD"
        echo "Path: $TWINGATE_PATH"
        echo "Install Type: $TWINGATE_INSTALL_TYPE"
        echo "Signature: $TWINGATE_SIGNATURE"
        echo "Status: Not running"
        echo "System Extension: $SYSTEM_EXT_STATUS"
        echo ""
        echo "Note: Twingate is installed but not currently running."
        
        # Return success - installed is what matters for this check
        exit $EXIT_SUCCESS
    fi
else
    log "Twingate NOT found in any location" "WARNING"
    log ""
    log "=========================================="
    log "Check Results: NOT INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Twingate Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    write_summary "CRITICAL" "Twingate is NOT installed"
    echo ""
    echo "Checked locations:"
    echo "  - /Applications/Twingate.app (system-wide)"
    echo "  - /Users/*/Applications/Twingate.app (per-user)"
    echo ""
    echo "To install Twingate, download from: https://www.twingate.com/download"
    
    exit $EXIT_CRITICAL
fi
