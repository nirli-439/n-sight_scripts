#!/bin/bash
# =============================================================================
# Install_DisplayLink_mac.sh - Install DisplayLink Manager for macOS (All Users)
# =============================================================================
#
# SYNOPSIS:
#     Downloads and installs DisplayLink Manager on macOS for ALL USERS.
#
# DESCRIPTION:
#     This remediation script installs DisplayLink Manager for USB docking
#     station display support. Features:
#     - Downloads official DisplayLink Manager PKG from Synaptics
#     - Installs system-wide for all users
#     - Verifies installation after completion
#     - Handles System Extension approval requirements (macOS 10.15+)
#     - Designed for N-Sight RMM deployment
#
#     IMPORTANT: After installation, users may need to:
#     1. Approve the System Extension in Security & Privacy preferences
#     2. Grant Screen Recording permission for DisplayLink Manager
#     3. Reboot the system for changes to take effect
#
#     Installation Details:
#     - Install Path: /Applications/DisplayLink Manager.app
#     - System Extension: com.displaylink.DisplayLinkDriverExtension
#
#     N-Sight Monitoring:
#     - Process Check: DisplayLinkUserAgent
#     - OSX Daemon Check: com.displaylink.DisplayLinkUserAgent
#     - LaunchAgent Path: /Library/LaunchAgents/com.displaylink.DisplayLinkUserAgent.plist
#
# EXIT CODES:
#     0    = Success (DisplayLink installed successfully)
#     1001 = Warning (DisplayLink already installed or needs user approval)
#     1002 = Critical/Error (Installation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Install_DisplayLink_mac.sh
#     Or:             bash /path/to/Install_DisplayLink_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_DisplayLink_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
# CHANGELOG:
#     v1.1 (2026-01-19): Updated download URL to v15.0, added Homebrew API fallback
#     v1.0: Initial release
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Install DisplayLink macOS (All Users)"
readonly SCRIPT_VERSION="1.1"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/DisplayLinkInstall_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# DisplayLink download URL (latest version from Synaptics)
# Note: This URL may need to be updated periodically as new versions are released
# Use Homebrew API to get latest: curl -s "https://formulae.brew.sh/api/cask/displaylink.json" | jq -r '.url'
readonly DISPLAYLINK_PKG_URL="https://www.synaptics.com/sites/default/files/exe_files/2025-12/DisplayLink%20Manager%20Graphics%20Connectivity15.0-EXE.pkg"
readonly DISPLAYLINK_FALLBACK_URL="https://www.synaptics.com/products/displaylink-graphics/downloads/macos"
readonly HOMEBREW_CASK_API="https://formulae.brew.sh/api/cask/displaylink.json"
readonly DOWNLOAD_PATH="/tmp/DisplayLinkManager.pkg"
readonly DMG_DOWNLOAD_PATH="/tmp/DisplayLinkManager.dmg"
readonly MOUNT_POINT="/Volumes/DisplayLink Manager"
readonly APP_NAME="DisplayLink Manager.app"
readonly INSTALL_PATH="/Applications/${APP_NAME}"

# DisplayLink bundle identifier
readonly DISPLAYLINK_BUNDLE_ID="com.displaylink.DisplayLinkUserAgent"
readonly DISPLAYLINK_EXTENSION_ID="com.displaylink.DisplayLinkDriverExtension"

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

get_macos_major_version() {
    local version
    version=$(sw_vers -productVersion 2>/dev/null)
    echo "$version" | cut -d. -f1
}

get_displaylink_version() {
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

check_displaylink_installed() {
    # Check system-wide /Applications folder
    if [ -d "$INSTALL_PATH" ]; then
        # Verify it's actually DisplayLink by checking bundle identifier
        local bundle_id
        bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$DISPLAYLINK_BUNDLE_ID" ] || [[ "$bundle_id" == *"displaylink"* ]] || [[ "$bundle_id" == *"DisplayLink"* ]]; then
            log "Found DisplayLink Manager in /Applications (system-wide)"
            return 0
        fi
    fi
    
    # Check all user home directories for per-user installations
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$DISPLAYLINK_BUNDLE_ID" ] || [[ "$bundle_id" == *"displaylink"* ]] || [[ "$bundle_id" == *"DisplayLink"* ]]; then
                        log "Found DisplayLink Manager in user directory: $user_app_path"
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Also check for DisplayLink via pkgutil (package receipts)
    if pkgutil --pkgs 2>/dev/null | grep -qi "displaylink"; then
        log "Found DisplayLink package receipt"
        return 0
    fi
    
    return 1
}

check_system_extension() {
    log "Checking DisplayLink system extension status..."
    
    # Check if the system extension is loaded
    local extension_status
    extension_status=$(systemextensionsctl list 2>/dev/null | grep -i "displaylink" || echo "")
    
    if [ -n "$extension_status" ]; then
        log "System extension status: $extension_status"
        
        if echo "$extension_status" | grep -q "activated enabled"; then
            log "DisplayLink system extension is activated and enabled"
            return 0
        elif echo "$extension_status" | grep -q "waiting"; then
            log "DisplayLink system extension is waiting for user approval" "WARNING"
            return 1
        fi
    else
        log "DisplayLink system extension not found in system extensions list"
    fi
    
    return 1
}

cleanup() {
    log "Performing cleanup..."
    
    # Unmount DMG if mounted
    if [ -d "$MOUNT_POINT" ]; then
        log "Unmounting DisplayLink DMG..."
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    
    # Also check for any other DisplayLink mount points
    for mount in /Volumes/DisplayLink*; do
        if [ -d "$mount" ]; then
            hdiutil detach "$mount" -quiet 2>/dev/null || true
        fi
    done
    
    # Remove downloaded files
    if [ -f "$DOWNLOAD_PATH" ]; then
        log "Removing downloaded PKG..."
        rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
    fi
    
    if [ -f "$DMG_DOWNLOAD_PATH" ]; then
        log "Removing downloaded DMG..."
        rm -f "$DMG_DOWNLOAD_PATH" 2>/dev/null || true
    fi
    
    log "Cleanup completed"
}

download_displaylink() {
    log "Downloading DisplayLink Manager..."
    
    # Remove any existing download
    rm -f "$DOWNLOAD_PATH" 2>/dev/null
    rm -f "$DMG_DOWNLOAD_PATH" 2>/dev/null
    
    local download_url=""
    
    # First, try to get the latest download URL from Homebrew's cask API
    log "Checking Homebrew cask API for latest DisplayLink version..."
    local homebrew_url
    homebrew_url=$(curl -sL --connect-timeout 10 "$HOMEBREW_CASK_API" 2>/dev/null | grep -o '"url":"[^"]*"' | head -1 | sed 's/"url":"//;s/"$//')
    
    if [ -n "$homebrew_url" ] && [[ "$homebrew_url" == http* ]]; then
        log "Found URL from Homebrew API: $homebrew_url"
        download_url="$homebrew_url"
    else
        log "Could not get URL from Homebrew API, using hardcoded URL"
        download_url="$DISPLAYLINK_PKG_URL"
    fi
    
    # Try direct PKG download
    log "Attempting download from: $download_url"
    
    if curl -L -o "$DOWNLOAD_PATH" "$download_url" --progress-bar -f 2>&1; then
        # Check if it's a PKG file
        local file_type
        file_type=$(file "$DOWNLOAD_PATH" 2>/dev/null || echo "")
        
        if echo "$file_type" | grep -qi "xar archive"; then
            log "Downloaded PKG installer successfully"
            return 0
        fi
    fi
    
    # If first URL fails and we got it from Homebrew, try hardcoded URL as fallback
    if [ "$download_url" != "$DISPLAYLINK_PKG_URL" ]; then
        log "Homebrew URL failed, trying hardcoded URL..."
        log "Attempting download from: $DISPLAYLINK_PKG_URL"
        
        if curl -L -o "$DOWNLOAD_PATH" "$DISPLAYLINK_PKG_URL" --progress-bar -f 2>&1; then
            local file_type
            file_type=$(file "$DOWNLOAD_PATH" 2>/dev/null || echo "")
            
            if echo "$file_type" | grep -qi "xar archive"; then
                log "Downloaded PKG installer successfully"
                return 0
            fi
        fi
    fi
    
    # If PKG download fails, try to download DMG from alternative sources
    log "Direct PKG download failed, trying alternative download methods..."
    
    # Try fetching download page and extracting DMG link
    local download_page
    download_page=$(curl -sL "https://www.synaptics.com/products/displaylink-graphics/downloads/macos" 2>/dev/null)
    
    if [ -n "$download_page" ]; then
        # Look for DMG or PKG download link
        local dmg_url
        dmg_url=$(echo "$download_page" | grep -oE 'https://[^"]+DisplayLink[^"]+\.(dmg|pkg)' | head -1)
        
        if [ -n "$dmg_url" ]; then
            log "Found download URL from page: $dmg_url"
            
            if [[ "$dmg_url" == *.pkg ]]; then
                if curl -L -o "$DOWNLOAD_PATH" "$dmg_url" --progress-bar -f 2>&1; then
                    log "Downloaded PKG installer successfully"
                    return 0
                fi
            elif [[ "$dmg_url" == *.dmg ]]; then
                if curl -L -o "$DMG_DOWNLOAD_PATH" "$dmg_url" --progress-bar -f 2>&1; then
                    log "Downloaded DMG successfully"
                    return 0
                fi
            fi
        fi
    fi
    
    # If all automatic downloads fail, provide manual instructions
    log "Automatic download failed" "ERROR"
    log "Please download DisplayLink Manager manually from:" "ERROR"
    log "$DISPLAYLINK_FALLBACK_URL" "ERROR"
    return 1
}

mount_dmg() {
    log "Mounting DisplayLink DMG..."
    
    # Unmount if already mounted
    if [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        sleep 1
    fi
    
    # Mount the DMG
    if hdiutil attach "$DMG_DOWNLOAD_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT" 2>/dev/null; then
        log "DMG mounted at: $MOUNT_POINT"
        return 0
    else
        # Try alternative mount (let system choose mount point)
        log "Trying alternative mount method..."
        local mount_output
        mount_output=$(hdiutil attach "$DMG_DOWNLOAD_PATH" -nobrowse 2>&1)
        
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

install_from_pkg() {
    log "Installing DisplayLink Manager from PKG..."
    
    local pkg_path="$1"
    
    if [ ! -f "$pkg_path" ]; then
        log "PKG file not found: $pkg_path" "ERROR"
        return 1
    fi
    
    # Install the package
    log "Running installer..."
    if installer -pkg "$pkg_path" -target / -verboseR 2>&1 | while read -r line; do
        log "$line"
    done; then
        log "Package installation completed"
        return 0
    else
        log "Package installation failed" "ERROR"
        return 1
    fi
}

install_from_dmg() {
    log "Installing DisplayLink Manager from DMG..."
    
    # Find the installer in the mounted volume
    local installer_path=""
    local pkg_path=""
    local app_path=""
    
    # Check for PKG installer in DMG
    pkg_path=$(find /Volumes -maxdepth 3 -name "*.pkg" -path "*DisplayLink*" 2>/dev/null | head -n 1)
    
    if [ -n "$pkg_path" ] && [ -f "$pkg_path" ]; then
        log "Found PKG installer in DMG: $pkg_path"
        return install_from_pkg "$pkg_path"
    fi
    
    # Check for app bundle in DMG
    app_path=$(find /Volumes -maxdepth 2 -name "DisplayLink Manager*.app" -type d 2>/dev/null | head -n 1)
    
    if [ -n "$app_path" ] && [ -d "$app_path" ]; then
        log "Found DisplayLink Manager.app at: $app_path"
        
        # Remove existing installation if present
        if [ -d "$INSTALL_PATH" ]; then
            log "Removing existing DisplayLink installation..."
            rm -rf "$INSTALL_PATH" 2>/dev/null
            
            if [ -d "$INSTALL_PATH" ]; then
                log "Failed to remove existing installation" "ERROR"
                return 1
            fi
        fi
        
        # Copy app to /Applications
        log "Copying DisplayLink Manager.app to /Applications..."
        if cp -R "$app_path" "/Applications/" 2>/dev/null; then
            log "DisplayLink Manager.app copied successfully"
            
            # Set proper ownership and permissions
            log "Setting ownership to root:wheel (system-wide access)..."
            chown -R root:wheel "$INSTALL_PATH" 2>/dev/null
            
            log "Setting permissions to 755 (all users can execute)..."
            chmod -R 755 "$INSTALL_PATH" 2>/dev/null
            
            # Clear quarantine attribute
            log "Clearing quarantine attribute..."
            xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
            
            log "App installation completed"
            return 0
        else
            log "Failed to copy DisplayLink Manager.app" "ERROR"
            return 1
        fi
    fi
    
    log "Could not find installer or app in mounted volume" "ERROR"
    log "Contents of /Volumes:"
    ls -la /Volumes/ >> "$LOG_FILE" 2>/dev/null
    return 1
}

verify_installation() {
    log "Verifying DisplayLink installation..."
    
    # Check for the application
    if [ -d "$INSTALL_PATH" ]; then
        log "DisplayLink Manager.app found in /Applications"
        
        # Get version
        local version
        version=$(get_displaylink_version "$INSTALL_PATH")
        log "Installed DisplayLink version: $version"
        
        # Verify code signature
        if codesign -v "$INSTALL_PATH" 2>/dev/null; then
            log "Code signature: Valid"
        else
            log "Code signature: Could not verify (may still work)" "WARNING"
        fi
        
        return 0
    fi
    
    # Check via pkgutil
    if pkgutil --pkgs 2>/dev/null | grep -qi "displaylink"; then
        log "DisplayLink package receipt found"
        return 0
    fi
    
    log "DisplayLink installation could not be verified" "ERROR"
    return 1
}

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

check_screen_recording_permission() {
    log "Note: DisplayLink requires Screen Recording permission"
    log "Users will need to grant this permission in System Preferences/Settings"
    log "Path: Security & Privacy > Privacy > Screen Recording > DisplayLink Manager"
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

# Check macOS version compatibility
macos_major=$(get_macos_major_version)
if [ "$macos_major" -lt 10 ]; then
    log "macOS version too old. DisplayLink requires macOS 10.15 (Catalina) or later" "ERROR"
    write_summary "CRITICAL" "macOS version not supported (requires 10.15+)"
    exit $EXIT_CRITICAL
fi

# Check if DisplayLink is already installed
log "Checking for existing DisplayLink installation..."
if check_displaylink_installed; then
    local_version=$(get_displaylink_version "$INSTALL_PATH")
    log "DisplayLink Manager is already installed (system-wide)"
    log "Version: $local_version"
    log "Path: $INSTALL_PATH"
    log "=========================================="
    
    # Check system extension status
    extension_ok=false
    if check_system_extension; then
        extension_ok=true
    fi
    
    echo ""
    echo "=========================================="
    echo "DisplayLink Manager Installation Status"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo ""
    
    if [ "$extension_ok" = true ]; then
        write_summary "OK" "DisplayLink already installed for ALL USERS (v${local_version})"
    else
        write_summary "WARNING" "DisplayLink installed but may need user approval for system extension"
    fi
    
    echo "Path: $INSTALL_PATH"
    echo "Version: $local_version"
    echo "Install Type: System-wide (/Applications)"
    
    if [ "$extension_ok" = true ]; then
        exit $EXIT_SUCCESS
    else
        echo ""
        echo "NOTE: User may need to approve System Extension in Security & Privacy"
        exit $EXIT_WARNING
    fi
fi

log "DisplayLink Manager is not installed. Starting installation..."
log ""

# Download DisplayLink
if ! download_displaylink; then
    log "Download failed" "ERROR"
    write_summary "CRITICAL" "Failed to download DisplayLink Manager"
    echo ""
    echo "Please download manually from: $DISPLAYLINK_FALLBACK_URL"
    exit $EXIT_CRITICAL
fi

# Install based on file type
if [ -f "$DOWNLOAD_PATH" ]; then
    # PKG installer
    if ! install_from_pkg "$DOWNLOAD_PATH"; then
        log "PKG installation failed" "ERROR"
        write_summary "CRITICAL" "Failed to install DisplayLink Manager"
        exit $EXIT_CRITICAL
    fi
elif [ -f "$DMG_DOWNLOAD_PATH" ]; then
    # DMG with embedded installer/app
    if ! mount_dmg; then
        log "Mount failed" "ERROR"
        write_summary "CRITICAL" "Failed to mount DisplayLink DMG"
        exit $EXIT_CRITICAL
    fi
    
    if ! install_from_dmg; then
        log "Installation failed" "ERROR"
        write_summary "CRITICAL" "Failed to install DisplayLink Manager"
        exit $EXIT_CRITICAL
    fi
else
    log "No installer file found" "ERROR"
    write_summary "CRITICAL" "Download completed but installer file not found"
    exit $EXIT_CRITICAL
fi

# Verify installation
if ! verify_installation; then
    log "Verification failed" "ERROR"
    write_summary "CRITICAL" "DisplayLink installation verification failed"
    exit $EXIT_CRITICAL
fi

# Check system extension status
check_system_extension
extension_approved=$?

# Note about Screen Recording permission
check_screen_recording_permission

# Get final version info
final_version=$(get_displaylink_version "$INSTALL_PATH")

log ""
log "=========================================="
log "Installation completed successfully!"
log "=========================================="

echo ""
echo "=========================================="
echo "DisplayLink Manager Installation Complete (All Users)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo ""

if [ $extension_approved -eq 0 ]; then
    write_summary "OK" "DisplayLink installed for ALL USERS (v${final_version})"
else
    write_summary "WARNING" "DisplayLink installed - user action may be required"
fi

echo "Path: $INSTALL_PATH"
echo "Version: $final_version"
echo "Install Type: System-wide (/Applications)"
echo ""
echo "IMPORTANT POST-INSTALLATION STEPS:"
echo "1. Approve System Extension: Security & Privacy > General > Allow"
echo "2. Grant Screen Recording: Security & Privacy > Privacy > Screen Recording"
echo "3. Restart the system for full functionality"
echo ""
echo "Users may see prompts to allow these permissions on first use."

if [ $extension_approved -eq 0 ]; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_WARNING
fi
