#!/bin/bash
# =============================================================================
# Check_TakeControl_Viewer_Installed.sh - Check if Take Control Viewer is installed on macOS
# =============================================================================
#
# SYNOPSIS:
#     Checks for Take Control Viewer for RMM installation on macOS and reports:
#     - Installation status (installed/not installed)
#     - Take Control Viewer version if installed
#     - Installation path and type (system-wide vs user)
#     - Running status
#     - TCC permissions status (Accessibility, Screen Recording, Full Disk Access)
#
# DESCRIPTION:
#     This monitoring script checks for Take Control Viewer installation by:
#     1. Checking /Applications (system-wide installation)
#     2. Checking all user ~/Applications folders
#     3. Reading version info from the app bundle
#     4. Checking if Take Control Viewer is currently running
#     5. Checking TCC permissions for all users
#
#     Designed for N-Sight RMM monitoring checks on macOS.
#     Pair with Install_TakeControl_Viewer_mac.sh for automated remediation.
#
# EXIT CODES:
#     0    = OK (Take Control Viewer is installed)
#     1001 = WARNING (Take Control Viewer installed but not running or missing permissions)
#     1002 = CRITICAL (Take Control Viewer is NOT installed)
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: No special privileges (runs as any user)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Usage:
#     - Deploy as 24x7 Check
#     - Set Install_TakeControl_Viewer_mac.sh as remediation task
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Take Control Viewer Installed"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/TakeControlViewerCheck_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Take Control Viewer application details
readonly APP_NAME="Take Control Viewer for RMM.app"
readonly SYSTEM_INSTALL_PATH="/Applications/${APP_NAME}"
# Bundle ID will be detected from installed app

# GitHub repository configuration (for auto-remediation)
readonly GITHUB_REPO="nirl-droid/n-sight_scripts"
readonly GITHUB_BRANCH="main"
readonly GITHUB_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"

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

get_viewer_version() {
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

get_viewer_build() {
    local app_path="$1"
    local build
    build=$(defaults read "${app_path}/Contents/Info" CFBundleVersion 2>/dev/null)
    
    if [ -n "$build" ]; then
        echo "$build"
    else
        echo "Unknown"
    fi
}

get_bundle_identifier() {
    local app_path="$1"
    local plist_path="${app_path}/Contents/Info.plist"
    
    if [ -f "$plist_path" ]; then
        local bundle_id
        bundle_id=$(defaults read "${app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ -n "$bundle_id" ]; then
            echo "$bundle_id"
            return 0
        fi
        
        # Fallback: try using PlistBuddy
        if [ -x /usr/libexec/PlistBuddy ]; then
            bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2>/dev/null)
            if [ -n "$bundle_id" ]; then
                echo "$bundle_id"
                return 0
            fi
        fi
    fi
    
    return 1
}

check_viewer_signed() {
    local app_path="$1"
    
    if codesign -v "$app_path" 2>/dev/null; then
        echo "Valid"
        return 0
    else
        echo "Invalid/Unsigned"
        return 1
    fi
}

check_viewer_running() {
    # Check for Take Control Viewer process
    if pgrep -f "Take Control Viewer" >/dev/null 2>&1; then
        return 0
    fi
    
    # Alternative: check for MSP Anywhere or TakeControl processes
    if pgrep -f "MSP Anywhere\|TakeControl\|Take Control" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

check_tcc_permission() {
    local service="$1"
    local bundle_id="$2"
    local user_home="$3"
    local tcc_db="${user_home}/Library/Application Support/com.apple.TCC/TCC.db"
    
    if [ ! -f "$tcc_db" ]; then
        return 1
    fi
    
    # Check if permission is granted (auth_value=2 means allowed)
    local count
    count=$(sqlite3 "$tcc_db" "SELECT COUNT(*) FROM access WHERE service='$service' AND client='$bundle_id' AND auth_value=2;" 2>/dev/null)
    
    if [ "$count" = "1" ]; then
        return 0
    fi
    
    return 1
}

check_user_tcc_permissions() {
    local bundle_id="$1"
    local user_home="$2"
    local username="$3"
    
    local accessibility=false
    local screen_recording=false
    local full_disk=false
    
    if check_tcc_permission "kTCCServiceAccessibility" "$bundle_id" "$user_home"; then
        accessibility=true
    fi
    
    if check_tcc_permission "kTCCServiceScreenCapture" "$bundle_id" "$user_home"; then
        screen_recording=true
    fi
    
    if check_tcc_permission "kTCCServiceSystemPolicyAllFiles" "$bundle_id" "$user_home"; then
        full_disk=true
    fi
    
    if [ "$accessibility" = true ] && [ "$screen_recording" = true ] && [ "$full_disk" = true ]; then
        log "User $username: All TCC permissions granted"
        return 0
    else
        log "User $username: Missing TCC permissions" "WARNING"
        log "  Accessibility: $([ "$accessibility" = true ] && echo "Granted" || echo "Missing")"
        log "  Screen Recording: $([ "$screen_recording" = true ] && echo "Granted" || echo "Missing")"
        log "  Full Disk Access: $([ "$full_disk" = true ] && echo "Granted" || echo "Missing")"
        return 1
    fi
}

check_all_tcc_permissions() {
    local bundle_id="$1"
    local users_with_permissions=0
    local users_without_permissions=0
    local total_users=0
    
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local username
                username=$(basename "$user_home")
                
                # Skip system users
                if [[ "$username" == ".*" ]] || [ "$username" = "root" ]; then
                    continue
                fi
                
                total_users=$((total_users + 1))
                
                if check_user_tcc_permissions "$bundle_id" "$user_home" "$username"; then
                    users_with_permissions=$((users_with_permissions + 1))
                else
                    users_without_permissions=$((users_without_permissions + 1))
                fi
            fi
        done
    fi
    
    if [ $users_without_permissions -gt 0 ]; then
        log "TCC Permissions: $users_with_permissions/$total_users users have all permissions" "WARNING"
        return 1
    elif [ $total_users -eq 0 ]; then
        log "TCC Permissions: No users found to check"
        return 0
    else
        log "TCC Permissions: All $total_users user(s) have all permissions granted"
        return 0
    fi
}

find_viewer_installation() {
    # Returns: path to Take Control Viewer.app if found, empty if not found
    # Sets global variables: VIEWER_PATH, VIEWER_INSTALL_TYPE
    
    # Check system-wide /Applications first (preferred)
    if [ -d "$SYSTEM_INSTALL_PATH" ]; then
        local bundle_id
        bundle_id=$(get_bundle_identifier "$SYSTEM_INSTALL_PATH")
        
        if [ -n "$bundle_id" ]; then
            VIEWER_PATH="$SYSTEM_INSTALL_PATH"
            VIEWER_INSTALL_TYPE="System-wide (all users)"
            BUNDLE_ID="$bundle_id"
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
                    bundle_id=$(get_bundle_identifier "$user_app_path")
                    
                    if [ -n "$bundle_id" ]; then
                        VIEWER_PATH="$user_app_path"
                        VIEWER_INSTALL_TYPE="User-level ($(basename "$user_home"))"
                        BUNDLE_ID="$bundle_id"
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Not found
    VIEWER_PATH=""
    VIEWER_INSTALL_TYPE=""
    BUNDLE_ID=""
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
VIEWER_PATH=""
VIEWER_INSTALL_TYPE=""
VIEWER_VERSION=""
VIEWER_BUILD=""
VIEWER_SIGNATURE=""
VIEWER_RUNNING=false
BUNDLE_ID=""
TCC_PERMISSIONS_OK=false

log "Searching for Take Control Viewer installation..."

# Find Take Control Viewer installation
if find_viewer_installation; then
    VIEWER_VERSION=$(get_viewer_version "$VIEWER_PATH")
    VIEWER_BUILD=$(get_viewer_build "$VIEWER_PATH")
    VIEWER_SIGNATURE=$(check_viewer_signed "$VIEWER_PATH")
    
    log "Take Control Viewer found!"
    log "Path: $VIEWER_PATH"
    log "Install Type: $VIEWER_INSTALL_TYPE"
    log "Version: $VIEWER_VERSION"
    log "Build: $VIEWER_BUILD"
    log "Bundle ID: $BUNDLE_ID"
    log "Signature: $VIEWER_SIGNATURE"
    
    # Check if Take Control Viewer is running
    if check_viewer_running; then
        VIEWER_RUNNING=true
        log "Running Status: Running"
    else
        log "Running Status: Not running"
    fi
    
    # Check TCC permissions
    log ""
    log "Checking TCC permissions..."
    if check_all_tcc_permissions "$BUNDLE_ID"; then
        TCC_PERMISSIONS_OK=true
    else
        TCC_PERMISSIONS_OK=false
    fi
    
    log ""
    log "=========================================="
    log "Check Results: INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Take Control Viewer Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    local exit_code=$EXIT_SUCCESS
    
    if [ "$TCC_PERMISSIONS_OK" = true ] && [ "$VIEWER_RUNNING" = true ]; then
        write_summary "OK" "Take Control Viewer v${VIEWER_VERSION} installed, running, and permissions granted"
        exit_code=$EXIT_SUCCESS
    elif [ "$TCC_PERMISSIONS_OK" = true ]; then
        write_summary "OK" "Take Control Viewer v${VIEWER_VERSION} installed with permissions granted"
        exit_code=$EXIT_SUCCESS
    else
        write_summary "WARNING" "Take Control Viewer v${VIEWER_VERSION} installed but missing TCC permissions"
        exit_code=$EXIT_WARNING
    fi
    
    echo "Version: $VIEWER_VERSION"
    echo "Build: $VIEWER_BUILD"
    echo "Path: $VIEWER_PATH"
    echo "Install Type: $VIEWER_INSTALL_TYPE"
    echo "Bundle ID: $BUNDLE_ID"
    echo "Signature: $VIEWER_SIGNATURE"
    echo "Status: $([ "$VIEWER_RUNNING" = true ] && echo "Running" || echo "Not running")"
    echo "TCC Permissions: $([ "$TCC_PERMISSIONS_OK" = true ] && echo "All granted" || echo "Some missing")"
    
    if [ "$TCC_PERMISSIONS_OK" = false ]; then
        echo ""
        echo "Note: Some users may be missing TCC permissions (Accessibility, Screen Recording, or Full Disk Access)."
        echo "Run Install_TakeControl_Viewer_mac.sh to grant permissions."
    fi
    
    exit $exit_code
else
    log "Take Control Viewer NOT found in any location" "WARNING"
    log ""
    log "=========================================="
    log "Check Results: NOT INSTALLED"
    log "=========================================="
    
    # Output results
    echo ""
    echo "=========================================="
    echo "Take Control Viewer Installation Check"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo "macOS: $(get_macos_name) $(get_macos_version)"
    echo ""
    
    write_summary "CRITICAL" "Take Control Viewer is NOT installed"
    echo ""
    echo "Checked locations:"
    echo "  - /Applications/Take Control Viewer for RMM.app (system-wide)"
    echo "  - /Users/*/Applications/Take Control Viewer for RMM.app (per-user)"
    echo ""
    
    # Auto-remediation: If running as root and deployed via GitHub, attempt installation
    if [[ $EUID -eq 0 ]]; then
        log "Running as root - attempting automatic installation..."
        echo "Attempting automatic installation..."
        
        # Download and run installation script from GitHub
        local install_script_url="${GITHUB_BASE_URL}/macos/takecontrol/Install_TakeControl_Viewer_mac.sh"
        local install_script="/tmp/Install_TakeControl_Viewer_$$.sh"
        
        log "Downloading installation script from GitHub..."
        if curl -fsSL "$install_script_url" -o "$install_script" 2>/dev/null; then
            if [ -f "$install_script" ]; then
                log "Running installation script..."
                chmod +x "$install_script" 2>/dev/null
                
                # Run installation script and capture result
                if bash "$install_script" >> "$LOG_FILE" 2>&1; then
                    local install_exit=$?
                    log "Installation script completed with exit code: $install_exit"
                    
                    # Verify installation succeeded
                    sleep 2
                    if [ -d "$SYSTEM_INSTALL_PATH" ]; then
                        log "Installation successful - Take Control Viewer is now installed" "SUCCESS"
                        echo "SUCCESS: Take Control Viewer has been automatically installed"
                        echo ""
                        echo "Installation completed via automatic remediation."
                        echo "The check will pass on the next run."
                        
                        # Clean up temp script
                        rm -f "$install_script" 2>/dev/null
                        
                        # Return success since we just installed it
                        exit $EXIT_SUCCESS
                    else
                        log "Installation script ran but app not found - may need manual intervention" "WARNING"
                        echo "WARNING: Installation script ran but verification failed"
                        echo "Please check logs or run installation manually"
                    fi
                else
                    log "Installation script failed" "ERROR"
                    echo "ERROR: Automatic installation failed"
                    echo "Check log file for details: $LOG_FILE"
                fi
                
                # Clean up temp script
                rm -f "$install_script" 2>/dev/null
            else
                log "Failed to download installation script" "ERROR"
            fi
        else
            log "Could not download installation script from GitHub" "WARNING"
            echo "Note: Automatic installation unavailable (GitHub download failed)"
        fi
    else
        echo "Note: Automatic installation requires root privileges"
        echo "Remediation: Run Install_TakeControl_Viewer_mac.sh as root to install Take Control Viewer for all users"
    fi
    
    echo ""
    echo "Remediation: Configure N-Sight to run Install_TakeControl_Viewer_mac.sh when this check fails"
    echo "Or run manually: curl -fsSL \"${GITHUB_BASE_URL}/macos/takecontrol/Install_TakeControl_Viewer_mac.sh\" | sudo bash"
    
    exit $EXIT_CRITICAL
fi
