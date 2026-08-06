#!/bin/bash
# =============================================================================
# Install_GoogleDrive_mac.sh - Install Google Drive for macOS (All Users)
# =============================================================================
#
# SYNOPSIS:
#     Downloads and installs Google Drive for Desktop on macOS for ALL USERS.
#
# DESCRIPTION:
#     This remediation script installs Google Drive when the check script
#     reports Google Drive is not installed. Features:
#     - Downloads official Google Drive DMG from Google
#     - Mounts DMG, copies app to /Applications (system-wide), unmounts
#     - SYSTEM-WIDE INSTALLATION: Installs to /Applications for ALL USERS
#     - Sets ownership to root:wheel with 755 permissions
#     - Verifies installation after completion
#     - Clears quarantine attribute for seamless first launch
#     - ADDS GOOGLE DRIVE ICON TO DOCK for all existing users
#     - Restarts Dock for logged-in users to apply changes immediately
#     - Designed for N-Sight RMM deployment
#
#     Installation Details:
#     - Install Path: /Applications/Google Drive.app (system-wide, all users)
#     - Ownership: root:wheel
#     - Permissions: 755 (rwxr-xr-x)
#     - Dock: Added to all user Docks automatically
#
# EXIT CODES:
#     0    = Success (Google Drive installed successfully)
#     1001 = Warning (Google Drive already installed)
#     1002 = Critical/Error (Installation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Install_GoogleDrive_mac.sh
#     Or:             bash /path/to/Install_GoogleDrive_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_GoogleDrive_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Usage:
#     - Create a Check using Check_GoogleDrive_Installed.sh
#     - Set this script as the automated task when check fails
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Install Google Drive macOS (All Users)"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/GoogleDriveInstall_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Google Drive download URL (universal binary for Apple Silicon and Intel)
readonly GOOGLEDRIVE_DMG_URL="https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
readonly DOWNLOAD_PATH="/tmp/GoogleDrive.dmg"
readonly MOUNT_POINT="/Volumes/Install Google Drive"
readonly APP_NAME="Google Drive.app"
readonly INSTALL_PATH="/Applications/${APP_NAME}"

# Google Drive bundle identifier
readonly GOOGLEDRIVE_BUNDLE_ID="com.google.drivefs"

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

get_googledrive_version() {
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

check_googledrive_installed() {
    # Check system-wide /Applications folder (primary check for all users install)
    if [ -d "$INSTALL_PATH" ]; then
        # Verify it's actually Google Drive by checking bundle identifier
        local bundle_id
        bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$GOOGLEDRIVE_BUNDLE_ID" ] || [[ "$bundle_id" == *"google"*"drive"* ]]; then
            log "Found Google Drive in /Applications (system-wide)"
            return 0
        fi
    fi
    
    # Check all user home directories for per-user installations
    # This helps detect if any user has Google Drive installed in their ~/Applications
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$GOOGLEDRIVE_BUNDLE_ID" ] || [[ "$bundle_id" == *"google"*"drive"* ]]; then
                        log "Found Google Drive in user directory: $user_app_path"
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
        log "Unmounting Google Drive DMG..."
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    
    # Also check for any other Google Drive mount points
    for mount in /Volumes/Install\ Google\ Drive* /Volumes/Google\ Drive*; do
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

download_googledrive() {
    log "Downloading Google Drive from: $GOOGLEDRIVE_DMG_URL"
    
    # Remove any existing download
    rm -f "$DOWNLOAD_PATH" 2>/dev/null
    
    # Download using curl with follow redirects, retry logic, and resume capability
    # --retry 5: retry up to 5 times on transient errors
    # --retry-delay 5: wait 5 seconds between retries
    # -C -: continue/resume partial download if possible
    if curl -L -o "$DOWNLOAD_PATH" "$GOOGLEDRIVE_DMG_URL" \
        --retry 5 --retry-delay 5 -C - \
        --progress-bar 2>&1; then
        log "Download completed successfully"
    else
        log "Failed to download Google Drive DMG after retries" "ERROR"
        return 1
    fi
    
    # Verify download exists and has reasonable size
    if [ ! -f "$DOWNLOAD_PATH" ]; then
        log "Downloaded file not found!" "ERROR"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$DOWNLOAD_PATH" 2>/dev/null || echo "0")
    # Ensure file_size is numeric (default to 0 if not)
    if ! [[ "$file_size" =~ ^[0-9]+$ ]]; then
        file_size=0
    fi
    local size_mb=$((file_size / 1024 / 1024))
    log "Downloaded file size: ${size_mb} MB"
    
    # Google Drive DMG should be at least 100MB
    if [ "$size_mb" -lt 100 ]; then
        log "Downloaded file appears too small (expected ~300MB+)" "WARNING"
    fi
    
    return 0
}

mount_dmg() {
    log "Mounting Google Drive DMG..."
    
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

install_googledrive() {
    log "Installing Google Drive to /Applications (SYSTEM-WIDE for ALL USERS)..."
    
    # Find the Google Drive.app in the mounted volume
    local source_app=""
    
    # Check standard mount point
    if [ -d "${MOUNT_POINT}/${APP_NAME}" ]; then
        source_app="${MOUNT_POINT}/${APP_NAME}"
    else
        # Search for Google Drive.app in /Volumes
        source_app=$(find /Volumes -maxdepth 2 -name "${APP_NAME}" -type d 2>/dev/null | head -n 1)
    fi
    
    if [ -z "$source_app" ] || [ ! -d "$source_app" ]; then
        log "Could not find Google Drive.app in mounted volume" "ERROR"
        log "Contents of /Volumes:"
        ls -la /Volumes/ >> "$LOG_FILE" 2>/dev/null
        
        # Check if there's a .pkg installer instead (Google sometimes uses this)
        local pkg_installer
        pkg_installer=$(find /Volumes -maxdepth 2 -name "*.pkg" 2>/dev/null | head -n 1)
        
        if [ -n "$pkg_installer" ] && [ -f "$pkg_installer" ]; then
            log "Found PKG installer: $pkg_installer"
            install_from_pkg "$pkg_installer"
            return $?
        fi
        
        return 1
    fi
    
    log "Found Google Drive.app at: $source_app"
    
    # Remove existing installation if present
    if [ -d "$INSTALL_PATH" ]; then
        log "Removing existing Google Drive installation..."
        rm -rf "$INSTALL_PATH" 2>/dev/null
        
        if [ -d "$INSTALL_PATH" ]; then
            log "Failed to remove existing installation" "ERROR"
            return 1
        fi
    fi
    
    # Copy Google Drive.app to /Applications
    log "Copying Google Drive.app to /Applications..."
    if cp -R "$source_app" "/Applications/" 2>/dev/null; then
        log "Google Drive.app copied successfully"
    else
        log "Failed to copy Google Drive.app to /Applications" "ERROR"
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
    
    log "System-wide installation completed - Google Drive available to ALL USERS"
    return 0
}

install_from_pkg() {
    local pkg_path="$1"
    log "Installing from PKG: $pkg_path"
    
    # Install the package silently
    if installer -pkg "$pkg_path" -target / 2>/dev/null; then
        log "PKG installation completed successfully"
        return 0
    else
        log "PKG installation failed" "ERROR"
        return 1
    fi
}

verify_installation() {
    log "Verifying Google Drive installation..."
    
    if [ ! -d "$INSTALL_PATH" ]; then
        log "Google Drive.app not found in /Applications" "ERROR"
        return 1
    fi
    
    # Verify bundle identifier
    local bundle_id
    bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
    
    if [ "$bundle_id" != "$GOOGLEDRIVE_BUNDLE_ID" ] && [[ "$bundle_id" != *"google"*"drive"* ]]; then
        log "Bundle identifier mismatch: $bundle_id" "ERROR"
        return 1
    fi
    
    # Get version
    local version
    version=$(get_googledrive_version "$INSTALL_PATH")
    log "Installed Google Drive version: $version"
    
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

add_to_dock_for_user() {
    local user_home="$1"
    local username="$2"
    local dock_plist="${user_home}/Library/Preferences/com.apple.dock.plist"
    
    # Skip if no dock plist exists (user never logged in)
    if [ ! -f "$dock_plist" ]; then
        log "No Dock plist found for user $username, skipping..."
        return 0
    fi
    
    # Check if Google Drive is already in the dock
    if /usr/libexec/PlistBuddy -c "Print :persistent-apps" "$dock_plist" 2>/dev/null | grep -q "Google Drive"; then
        log "Google Drive already in Dock for user $username"
        return 0
    fi
    
    log "Adding Google Drive to Dock for user $username..."
    
    # Create dock item entry using PlistBuddy
    local dock_entry="<dict>
        <key>tile-data</key>
        <dict>
            <key>file-data</key>
            <dict>
                <key>_CFURLString</key>
                <string>file://${INSTALL_PATH}/</string>
                <key>_CFURLStringType</key>
                <integer>15</integer>
            </dict>
            <key>file-label</key>
            <string>Google Drive</string>
            <key>file-type</key>
            <integer>41</integer>
        </dict>
        <key>tile-type</key>
        <string>file-tile</string>
    </dict>"
    
    # Get current count of persistent-apps
    local app_count
    app_count=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps" "$dock_plist" 2>/dev/null | grep -c "Dict" || echo "0")
    
    # Add the new entry at the end of persistent-apps
    if /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data dict" "$dock_plist" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data:file-data dict" "$dock_plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data:file-data:_CFURLString string 'file://${INSTALL_PATH}/'" "$dock_plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data:file-data:_CFURLStringType integer 15" "$dock_plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data:file-label string 'Google Drive'" "$dock_plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-data:file-type integer 41" "$dock_plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :persistent-apps:${app_count}:tile-type string 'file-tile'" "$dock_plist" 2>/dev/null
        
        # Fix ownership of the plist file
        local uid gid
        uid=$(stat -f%u "$user_home")
        gid=$(stat -f%g "$user_home")
        chown "${uid}:${gid}" "$dock_plist" 2>/dev/null
        
        log "Successfully added Google Drive to Dock for user $username"
        return 0
    else
        log "Failed to add Google Drive to Dock for user $username" "WARNING"
        return 1
    fi
}

add_to_dock_all_users() {
    log "Adding Google Drive to Dock for all users..."
    
    local users_dir="/Users"
    local success_count=0
    local fail_count=0
    
    # Iterate through all user home directories
    for user_home in "$users_dir"/*; do
        if [ -d "$user_home" ]; then
            local username
            username=$(basename "$user_home")
            
            # Skip system directories
            case "$username" in
                Shared|.localized|Guest)
                    continue
                    ;;
            esac
            
            # Skip if not a real user home directory
            if [ ! -d "${user_home}/Library" ]; then
                continue
            fi
            
            if add_to_dock_for_user "$user_home" "$username"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        fi
    done
    
    log "Dock update complete: $success_count users updated, $fail_count failed"
    
    # Restart Dock for currently logged-in users to apply changes
    log "Restarting Dock to apply changes..."
    
    # Get list of logged-in users (console users)
    local logged_in_users
    logged_in_users=$(who | grep console | awk '{print $1}' | sort -u)
    
    for user in $logged_in_users; do
        log "Restarting Dock for logged-in user: $user"
        sudo -u "$user" killall Dock 2>/dev/null || true
    done
    
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

# Check if Google Drive is already installed (system-wide)
log "Checking for existing Google Drive installation in /Applications..."
if check_googledrive_installed; then
    local_version=$(get_googledrive_version "$INSTALL_PATH")
    log "Google Drive is already installed (system-wide)"
    log "Version: $local_version"
    log "Path: $INSTALL_PATH"
    log "Install Type: System-wide (all users)"
    
    # Still add to Dock for all users (ensures new users or users without dock icon get it)
    log "Ensuring Google Drive is in Dock for all users..."
    add_to_dock_all_users
    
    log "=========================================="
    
    echo ""
    echo "=========================================="
    echo "Google Drive Installation Status"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo ""
    write_summary "OK" "Google Drive already installed for ALL USERS (v${local_version})"
    echo "Path: $INSTALL_PATH"
    echo "Install Type: System-wide (/Applications)"
    echo "Dock: Verified/Added to all user Docks"
    
    exit $EXIT_SUCCESS
fi

log "Google Drive is not installed. Starting installation..."
log ""

# Download Google Drive DMG
if ! download_googledrive; then
    log "Download failed" "ERROR"
    write_summary "CRITICAL" "Failed to download Google Drive DMG"
    exit $EXIT_CRITICAL
fi

# Mount the DMG
if ! mount_dmg; then
    log "Mount failed" "ERROR"
    write_summary "CRITICAL" "Failed to mount Google Drive DMG"
    exit $EXIT_CRITICAL
fi

# Install Google Drive
if ! install_googledrive; then
    log "Installation failed" "ERROR"
    write_summary "CRITICAL" "Failed to install Google Drive"
    exit $EXIT_CRITICAL
fi

# Verify installation
if ! verify_installation; then
    log "Verification failed" "ERROR"
    write_summary "CRITICAL" "Google Drive installation verification failed"
    exit $EXIT_CRITICAL
fi

# Add Google Drive to Dock for all users
add_to_dock_all_users

# Get final version info
final_version=$(get_googledrive_version "$INSTALL_PATH")

log ""
log "=========================================="
log "Installation completed successfully!"
log "=========================================="

echo ""
echo "=========================================="
echo "Google Drive Installation Complete (All Users)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo ""
write_summary "OK" "Google Drive installed for ALL USERS (v${final_version})"
echo "Path: $INSTALL_PATH"
echo "Version: $final_version"
echo "Install Type: System-wide (/Applications)"
echo "Ownership: root:wheel"
echo "Permissions: 755 (all users can execute)"
echo "Dock: Added to all user Docks"
echo ""
echo "NOTE: User must sign in to Google Drive after first launch"

exit $EXIT_SUCCESS
