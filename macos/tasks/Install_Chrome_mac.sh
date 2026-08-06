#!/bin/bash
# =============================================================================
# Install_Chrome_mac.sh - Install Google Chrome for macOS (All Users)
# =============================================================================
#
# SYNOPSIS:
#     Downloads and installs Google Chrome browser on macOS for ALL USERS.
#
# DESCRIPTION:
#     This remediation script installs Google Chrome when the check script
#     reports Chrome is not installed. Features:
#     - Downloads official Chrome DMG from Google
#     - Mounts DMG, copies app to /Applications (system-wide), unmounts
#     - SYSTEM-WIDE INSTALLATION: Installs to /Applications for ALL USERS
#     - Sets ownership to root:wheel with 755 permissions
#     - Verifies installation after completion
#     - Clears quarantine attribute for seamless first launch
#     - Adds Chrome icon to Dock for all users
#     - Designed for N-Sight RMM deployment
#
#     Installation Details:
#     - Install Path: /Applications/Google Chrome.app (system-wide, all users)
#     - Ownership: root:wheel
#     - Permissions: 755 (rwxr-xr-x)
#
# EXIT CODES:
#     0    = Success (Chrome installed successfully)
#     1001 = Warning (Chrome already installed)
#     1002 = Critical/Error (Installation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Install_Chrome_mac.sh
#     Or:             bash /path/to/Install_Chrome_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_Chrome_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Usage:
#     - Create a Check using Check_Chrome_Installed.sh
#     - Set this script as the automated task when check fails
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Install Chrome macOS (All Users)"
readonly SCRIPT_VERSION="1.1"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/ChromeInstall_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Chrome download URL (universal binary for Apple Silicon and Intel)
readonly CHROME_DMG_URL="https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
readonly DOWNLOAD_PATH="/tmp/GoogleChrome.dmg"
readonly MOUNT_POINT="/Volumes/Google Chrome"
readonly APP_NAME="Google Chrome.app"
readonly INSTALL_PATH="/Applications/${APP_NAME}"

# Chrome bundle identifier
readonly CHROME_BUNDLE_ID="com.google.Chrome"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    
    # Output to both stdout and log file
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

check_chrome_installed() {
    # Check system-wide /Applications folder (primary check for all users install)
    if [ -d "$INSTALL_PATH" ]; then
        # Verify it's actually Chrome by checking bundle identifier
        local bundle_id
        bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
            log "Found Google Chrome in /Applications (system-wide)"
            return 0
        fi
    fi
    
    # Check all user home directories for per-user installations
    # This helps detect if any user has Chrome installed in their ~/Applications
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
                        log "Found Google Chrome in user directory: $user_app_path"
                        # Note: We'll still install to /Applications for system-wide access
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    return 1
}

cleanup() {
    log "Performing cleanup..."
    
    # Unmount DMG if mounted
    if [ -d "$MOUNT_POINT" ]; then
        log "Unmounting Chrome DMG..."
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    
    # Also check for any other Chrome mount points
    for mount in /Volumes/Google\ Chrome*; do
        if [ -d "$mount" ]; then
            hdiutil detach "$mount" -quiet 2>/dev/null || true
        fi
    done
    
    # Remove downloaded DMG
    if [ -f "$DOWNLOAD_PATH" ]; then
        log "Removing downloaded DMG..."
        rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
    fi
    
    log "Cleanup completed"
}

download_chrome() {
    log "Downloading Google Chrome from: $CHROME_DMG_URL"
    
    # Remove any existing download
    rm -f "$DOWNLOAD_PATH" 2>/dev/null
    
    # Download using curl with follow redirects
    if curl -L -o "$DOWNLOAD_PATH" "$CHROME_DMG_URL" --progress-bar 2>&1; then
        log "Download completed successfully"
    else
        log "Failed to download Chrome DMG" "ERROR"
        return 1
    fi
    
    # Verify download exists and has reasonable size
    if [ ! -f "$DOWNLOAD_PATH" ]; then
        log "Downloaded file not found!" "ERROR"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$DOWNLOAD_PATH" 2>/dev/null || echo "0")
    local size_mb=$((file_size / 1024 / 1024))
    log "Downloaded file size: ${size_mb} MB"
    
    # Chrome DMG should be at least 150MB
    if [ "$size_mb" -lt 100 ]; then
        log "Downloaded file appears too small (expected ~200MB+)" "WARNING"
    fi
    
    return 0
}

mount_dmg() {
    log "Mounting Chrome DMG..."
    
    # Unmount if already mounted
    if [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        sleep 1
    fi
    
    # Mount the DMG
    if hdiutil attach "$DOWNLOAD_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT" 2>/dev/null; then
        log "DMG mounted at: $MOUNT_POINT"
        return 0
    else
        # Try alternative mount (let system choose mount point)
        log "Trying alternative mount method..."
        local mount_output
        mount_output=$(hdiutil attach "$DOWNLOAD_PATH" -nobrowse 2>&1)
        
        if [ $? -eq 0 ]; then
            log "DMG mounted successfully"
            log "Mount output: $mount_output"
            return 0
        else
            log "Failed to mount DMG: $mount_output" "ERROR"
            return 1
        fi
    fi
}

install_chrome() {
    log "Installing Google Chrome to /Applications (SYSTEM-WIDE for ALL USERS)..."
    
    # Find the Google Chrome.app in the mounted volume
    local source_app=""
    
    # Check standard mount point
    if [ -d "${MOUNT_POINT}/${APP_NAME}" ]; then
        source_app="${MOUNT_POINT}/${APP_NAME}"
    else
        # Search for Google Chrome.app in /Volumes
        source_app=$(find /Volumes -maxdepth 2 -name "${APP_NAME}" -type d 2>/dev/null | head -n 1)
    fi
    
    if [ -z "$source_app" ] || [ ! -d "$source_app" ]; then
        log "Could not find Google Chrome.app in mounted volume" "ERROR"
        log "Contents of /Volumes:"
        ls -la /Volumes/ >> "$LOG_FILE" 2>/dev/null
        return 1
    fi
    
    log "Found Google Chrome.app at: $source_app"
    
    # Remove existing installation if present
    if [ -d "$INSTALL_PATH" ]; then
        log "Removing existing Chrome installation..."
        rm -rf "$INSTALL_PATH" 2>/dev/null
        
        if [ -d "$INSTALL_PATH" ]; then
            log "Failed to remove existing installation" "ERROR"
            return 1
        fi
    fi
    
    # Copy Google Chrome.app to /Applications
    log "Copying Google Chrome.app to /Applications..."
    if cp -R "$source_app" "/Applications/" 2>/dev/null; then
        log "Google Chrome.app copied successfully"
    else
        log "Failed to copy Google Chrome.app to /Applications" "ERROR"
        return 1
    fi
    
    # Set proper ownership and permissions for ALL USERS access
    log "Setting ownership to root:wheel (system-wide access)..."
    chown -R root:wheel "$INSTALL_PATH" 2>/dev/null
    
    log "Setting permissions to 755 (all users can execute)..."
    chmod -R 755 "$INSTALL_PATH" 2>/dev/null
    
    # Clear quarantine attribute (allows app to run without Gatekeeper prompt)
    log "Clearing quarantine attribute..."
    xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
    
    log "System-wide installation completed - Chrome available to ALL USERS"
    return 0
}

verify_installation() {
    log "Verifying Chrome installation..."
    
    if [ ! -d "$INSTALL_PATH" ]; then
        log "Google Chrome.app not found in /Applications" "ERROR"
        return 1
    fi
    
    # Verify bundle identifier
    local bundle_id
    bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
    
    if [ "$bundle_id" != "$CHROME_BUNDLE_ID" ] && [[ "$bundle_id" != *"Chrome"* ]]; then
        log "Bundle identifier mismatch: $bundle_id" "ERROR"
        return 1
    fi
    
    # Get version
    local version
    version=$(get_chrome_version "$INSTALL_PATH")
    log "Installed Chrome version: $version"
    
    # Verify code signature
    if codesign -v "$INSTALL_PATH" 2>/dev/null; then
        log "Code signature: Valid"
    else
        log "Code signature: Could not verify (may still work)" "WARNING"
    fi
    
    return 0
}

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

add_to_dock() {
    log "Adding Google Chrome to Dock for all users..."
    
    local app_path="$INSTALL_PATH"
    local users_added=0
    local users_skipped=0
    
    # Iterate through all user directories
    for user_home in /Users/*; do
        # Skip non-directories and system directories
        [ ! -d "$user_home" ] && continue
        local username
        username=$(basename "$user_home")
        
        # Skip system accounts and Shared folder
        case "$username" in
            Shared|.localized|Guest) continue ;;
        esac
        
        # Check if user has a valid home directory structure
        [ ! -d "${user_home}/Library/Preferences" ] && continue
        
        local dock_plist="${user_home}/Library/Preferences/com.apple.dock.plist"
        
        # Check if Chrome is already in the Dock
        if [ -f "$dock_plist" ]; then
            if /usr/libexec/PlistBuddy -c "Print persistent-apps" "$dock_plist" 2>/dev/null | grep -q "Google Chrome.app"; then
                log "Chrome already in Dock for user: $username"
                ((users_skipped++))
                continue
            fi
        fi
        
        # Create dock entry using PlistBuddy
        # Get the current number of persistent apps
        local app_count=0
        if [ -f "$dock_plist" ]; then
            app_count=$(/usr/libexec/PlistBuddy -c "Print persistent-apps" "$dock_plist" 2>/dev/null | grep -c "Dict" || echo "0")
        fi
        
        log "Adding Chrome to Dock for user: $username (position: $app_count)"
        
        # Add Chrome to the dock
        if [ -f "$dock_plist" ]; then
            /usr/libexec/PlistBuddy -c "Add persistent-apps:${app_count}:tile-data dict" "$dock_plist" 2>/dev/null
            /usr/libexec/PlistBuddy -c "Add persistent-apps:${app_count}:tile-data:file-data dict" "$dock_plist" 2>/dev/null
            /usr/libexec/PlistBuddy -c "Add persistent-apps:${app_count}:tile-data:file-data:_CFURLString string file://${app_path}/" "$dock_plist" 2>/dev/null
            /usr/libexec/PlistBuddy -c "Add persistent-apps:${app_count}:tile-data:file-data:_CFURLStringType integer 15" "$dock_plist" 2>/dev/null
            /usr/libexec/PlistBuddy -c "Add persistent-apps:${app_count}:tile-type string file-tile" "$dock_plist" 2>/dev/null
            
            # Set correct ownership on the plist
            local uid gid
            uid=$(stat -f %u "$user_home")
            gid=$(stat -f %g "$user_home")
            chown "$uid:$gid" "$dock_plist" 2>/dev/null
            
            ((users_added++))
            log "Successfully added Chrome to Dock for: $username"
        else
            log "No dock plist found for user: $username - will use defaults on first login" "WARNING"
            ((users_skipped++))
        fi
    done
    
    # Restart Dock for all logged-in users to apply changes
    log "Restarting Dock to apply changes..."
    killall Dock 2>/dev/null || true
    
    log "Dock update complete: $users_added users updated, $users_skipped skipped"
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Trap to ensure cleanup runs on exit
trap cleanup EXIT

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "macOS: $(get_macos_name) $(get_macos_version)"
log "Build: $(sw_vers -buildVersion 2>/dev/null || echo 'Unknown')"
log "Architecture: $(uname -m)"
log "User: $(whoami)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# Check if Chrome is already installed (system-wide)
log "Checking for existing Chrome installation in /Applications..."
if check_chrome_installed; then
    local_version=$(get_chrome_version "$INSTALL_PATH")
    log "Google Chrome is already installed (system-wide)"
    log "Version: $local_version"
    log "Path: $INSTALL_PATH"
    log "Install Type: System-wide (all users)"
    log "=========================================="
    
    echo ""
    echo "=========================================="
    echo "Google Chrome Installation Status"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo ""
    write_summary "OK" "Chrome already installed for ALL USERS (v${local_version})"
    echo "Path: $INSTALL_PATH"
    echo "Install Type: System-wide (/Applications)"
    
    exit $EXIT_SUCCESS
fi

log "Google Chrome is not installed. Starting installation..."
log ""

# Download Chrome DMG
if ! download_chrome; then
    log "Download failed" "ERROR"
    write_summary "CRITICAL" "Failed to download Chrome DMG"
    exit $EXIT_CRITICAL
fi

# Mount the DMG
if ! mount_dmg; then
    log "Mount failed" "ERROR"
    write_summary "CRITICAL" "Failed to mount Chrome DMG"
    exit $EXIT_CRITICAL
fi

# Install Chrome
if ! install_chrome; then
    log "Installation failed" "ERROR"
    write_summary "CRITICAL" "Failed to install Chrome"
    exit $EXIT_CRITICAL
fi

# Verify installation
if ! verify_installation; then
    log "Verification failed" "ERROR"
    write_summary "CRITICAL" "Chrome installation verification failed"
    exit $EXIT_CRITICAL
fi

# Add Chrome to Dock for all users
add_to_dock

# Get final version info
final_version=$(get_chrome_version "$INSTALL_PATH")

log ""
log "=========================================="
log "Installation completed successfully!"
log "=========================================="

echo ""
echo "=========================================="
echo "Google Chrome Installation Complete (All Users)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo ""
write_summary "OK" "Chrome installed for ALL USERS (v${final_version})"
echo "Path: $INSTALL_PATH"
echo "Version: $final_version"
echo "Install Type: System-wide (/Applications)"
echo "Ownership: root:wheel"
echo "Permissions: 755 (all users can execute)"
echo "Dock: Added for all users"

exit $EXIT_SUCCESS
