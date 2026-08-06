#!/bin/bash
# =============================================================================
# Install_Tailscale_mac.sh - Install Tailscale for macOS (All Users)
# =============================================================================
#
# SYNOPSIS:
#     Downloads and installs Tailscale VPN client on macOS for ALL USERS.
#     Specifically designed for macOS 12.x (Monterey) and later.
#
# DESCRIPTION:
#     This remediation script installs Tailscale when the check script reports
#     Tailscale is not installed. Features:
#     - Downloads Tailscale PKG from pkgs.tailscale.com (uses version 1.90.9 for macOS 12.x compatibility)
#     - Falls back to older versions if primary download fails
#     - Installs PKG using macOS installer command (system-wide)
#     - SYSTEM-WIDE INSTALLATION: Installs to /Applications for ALL USERS
#     - Sets proper permissions and ownership
#     - Verifies installation after completion
#     - Clears quarantine attribute for seamless first launch
#     - Designed for N-Sight RMM deployment
#     - Optimized for macOS 12.x (Monterey) compatibility
#
#     Installation Details:
#     - Install Path: /Applications/Tailscale.app (system-wide, all users)
#     - System Extension: Installed and requires approval (user interaction may be needed)
#     - Ownership: root:wheel
#     - Permissions: 755 (rwxr-xr-x)
#
# EXIT CODES:
#     0    = Success (Tailscale installed successfully)
#     1001 = Warning (Tailscale already installed)
#     1002 = Critical/Error (Installation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Install_Tailscale_mac.sh
#     Or:             bash /path/to/Install_Tailscale_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_Tailscale_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Root privileges (sudo)
#     Platform: macOS 12.0+ (Monterey and later)
#
#     IMPORTANT NOTES:
#     - Uses Tailscale 1.90.9 by default (compatible with macOS 12.x)
#     - Falls back to 1.88.4 or latest if primary version unavailable
#     - Tailscale uses a PKG installer (not DMG)
#     - System Extension approval may require user interaction after installation
#     - Users may need to approve the system extension in System Preferences > Security & Privacy
#     - Tailscale daemon runs as a LaunchDaemon (requires root)
#
#     N-Sight Usage:
#     - Create a Check using Check_Tailscale_Installed.sh
#     - Set this script as the automated task when check fails
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Install Tailscale macOS (All Users)"
readonly SCRIPT_VERSION="1.1"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/TailscaleInstall_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Tailscale download URLs - use older versions ONLY for macOS 12.x compatibility
# Version 1.90.9 is known to work with macOS 12.x (Monterey)
# DO NOT use latest version as it may require newer macOS
readonly TAILSCALE_PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-1.90.9-macos.pkg"
readonly TAILSCALE_FALLBACK_URL="https://pkgs.tailscale.com/stable/Tailscale-1.88.4-macos.pkg"
readonly TAILSCALE_FALLBACK2_URL="https://pkgs.tailscale.com/stable/Tailscale-1.86.4-macos.pkg"
readonly DOWNLOAD_PATH="/tmp/Tailscale-macos.pkg"
readonly APP_NAME="Tailscale.app"
readonly INSTALL_PATH="/Applications/${APP_NAME}"

# Tailscale bundle identifier
readonly TAILSCALE_BUNDLE_ID="com.tailscale.ipn.macos"

# Minimum macOS version required (12.0 = Monterey)
readonly MIN_MACOS_VERSION="12.0"

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

compare_versions() {
    # Compare two version strings (e.g., "12.0" vs "12.1")
    # Returns 0 if first >= second, 1 otherwise
    local version1="$1"
    local version2="$2"
    
    # Simple brute-force numeric comparison
    # Extract major and minor as integers
    local v1_major v1_minor v2_major v2_minor
    
    # Get major version (first number before first dot)
    v1_major=$(echo "$version1" | awk -F. '{print $1+0}')
    v1_minor=$(echo "$version1" | awk -F. '{print ($2+0)}')
    v2_major=$(echo "$version2" | awk -F. '{print $1+0}')
    v2_minor=$(echo "$version2" | awk -F. '{print ($2+0)}')
    
    # Default to 0 if empty
    v1_major=${v1_major:-0}
    v1_minor=${v1_minor:-0}
    v2_major=${v2_major:-0}
    v2_minor=${v2_minor:-0}
    
    # Compare: version1 >= version2?
    if [ "$v1_major" -gt "$v2_major" ]; then
        return 0  # version1 > version2
    elif [ "$v1_major" -lt "$v2_major" ]; then
        return 1  # version1 < version2
    else
        # Major versions equal, compare minor
        if [ "$v1_minor" -ge "$v2_minor" ]; then
            return 0  # version1 >= version2
        else
            return 1  # version1 < version2
        fi
    fi
}

check_macos_version() {
    local current_version
    current_version=$(get_macos_version)
    
    log "Checking macOS version compatibility..."
    log "Current macOS version: $current_version"
    log "Minimum required version: $MIN_MACOS_VERSION"
    
    # Validate version format
    if [ "$current_version" = "Unknown" ] || [ -z "$current_version" ]; then
        log "Unable to determine macOS version" "ERROR"
        return 1
    fi
    
    # Extract major.minor version (e.g., "12.0" from "12.0.1")
    local major_minor
    major_minor=$(echo "$current_version" | cut -d. -f1-2)
    
    # Ensure we have at least major.minor format
    if [ -z "$major_minor" ] || [ "$major_minor" = "$current_version" ]; then
        # If cut didn't work or version is already major.minor, use as-is
        major_minor="$current_version"
    fi
    
    log "Comparing versions: $major_minor >= $MIN_MACOS_VERSION"
    
    # Extract major version number for fallback check
    local current_major
    current_major=$(echo "$current_version" | cut -d. -f1)
    local required_major
    required_major=$(echo "$MIN_MACOS_VERSION" | cut -d. -f1)
    
    # Try the comparison
    if compare_versions "$major_minor" "$MIN_MACOS_VERSION"; then
        log "macOS version check passed: $major_minor >= $MIN_MACOS_VERSION"
        return 0
    else
        # Fallback: if major version matches and we're on 12.x, proceed anyway
        if [ "$current_major" -ge "$required_major" ] 2>/dev/null; then
            log "Version comparison failed, but major version $current_major >= $required_major" "WARNING"
            log "Proceeding with installation (macOS $current_version should be compatible)" "WARNING"
            return 0
        fi
        
        log "macOS version comparison failed: $major_minor < $MIN_MACOS_VERSION" "ERROR"
        log "Current version details - Full: $current_version, Major.Minor: $major_minor, Major: $current_major" "ERROR"
        log "Required version - Full: $MIN_MACOS_VERSION, Major: $required_major" "ERROR"
        return 1
    fi
}

get_tailscale_version() {
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

check_tailscale_installed() {
    # Check system-wide /Applications folder (primary check for all users install)
    if [ -d "$INSTALL_PATH" ]; then
        # Verify it's actually Tailscale by checking bundle identifier
        local bundle_id
        bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$TAILSCALE_BUNDLE_ID" ] || [[ "$bundle_id" == *"tailscale"* ]]; then
            log "Found Tailscale in /Applications (system-wide)"
            return 0
        fi
    fi
    
    # Check all user home directories for per-user installations
    # This helps detect if any user has Tailscale installed in their ~/Applications
    local users_dir="/Users"
    if [ -d "$users_dir" ]; then
        for user_home in "$users_dir"/*; do
            if [ -d "$user_home" ] && [ "$(basename "$user_home")" != "Shared" ]; then
                local user_app_path="${user_home}/Applications/${APP_NAME}"
                if [ -d "$user_app_path" ]; then
                    local bundle_id
                    bundle_id=$(defaults read "${user_app_path}/Contents/Info" CFBundleIdentifier 2>/dev/null)
                    
                    if [ "$bundle_id" = "$TAILSCALE_BUNDLE_ID" ] || [[ "$bundle_id" == *"tailscale"* ]]; then
                        log "Found Tailscale in user directory: $user_app_path"
                        # Note: We'll still install to /Applications for system-wide access
                        return 0
                    fi
                fi
            fi
        done
    fi
    
    # Also check if Tailscale daemon is running (indicates installation)
    if launchctl list 2>/dev/null | grep -q "com.tailscale"; then
        log "Found Tailscale daemon running (indicates installation)"
        return 0
    fi
    
    return 1
}

cleanup() {
    log "Performing cleanup..."
    
    # Remove downloaded PKG
    if [ -f "$DOWNLOAD_PATH" ]; then
        log "Removing downloaded PKG..."
        rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
    fi
    
    log "Cleanup completed"
}

download_tailscale() {
    # Try multiple Tailscale versions for macOS 12.x compatibility
    # Only use older versions - never use "latest" as it may require newer macOS
    local urls=("$TAILSCALE_PKG_URL" "$TAILSCALE_FALLBACK_URL" "$TAILSCALE_FALLBACK2_URL")
    local url_names=("Tailscale 1.90.9 (macOS 12.x compatible)" "Tailscale 1.88.4 (fallback)" "Tailscale 1.86.4 (fallback)")
    
    # Remove any existing download
    rm -f "$DOWNLOAD_PATH" 2>/dev/null
    
    # Try each URL in sequence
    for i in "${!urls[@]}"; do
        local url="${urls[$i]}"
        local url_name="${url_names[$i]}"
        
        log "Attempting to download $url_name from: $url"
        echo "Downloading $url_name..."
        
        # Check if URL exists and get final URL (after redirects)
        local final_url http_code
        http_code=$(curl -s -L -I -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
        final_url=$(curl -s -L -I -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)
        
        # Reject if redirected to "latest" or if URL doesn't exist
        if echo "$final_url" | grep -qi "latest"; then
            log "URL redirected to 'latest' version - skipping for macOS 12.x compatibility" "WARNING"
            log "Original: $url -> Redirected to: $final_url" "WARNING"
            continue
        fi
        
        if [ "$http_code" != "200" ]; then
            log "URL returned HTTP $http_code - file may not exist" "WARNING"
            log "URL: $url" "WARNING"
            continue
        fi
        
        log "Verified URL exists: $final_url"
        
        # Download using curl with progress bar
        local curl_exit=0
        curl -L -f -o "$DOWNLOAD_PATH" "$url" \
            --progress-bar \
            --connect-timeout 30 \
            --max-time 300 2>&1 || curl_exit=$?
        
        echo ""  # New line after progress bar
        
        if [ $curl_exit -eq 0 ] && [ -f "$DOWNLOAD_PATH" ] && [ -s "$DOWNLOAD_PATH" ]; then
            log "Download completed successfully: $url_name"
            log "Source URL: $final_url"
            
            # Verify download exists and has reasonable size
            if [ ! -f "$DOWNLOAD_PATH" ]; then
                log "Downloaded file not found!" "WARNING"
                continue
            fi
            
            local file_size
            file_size=$(stat -f%z "$DOWNLOAD_PATH" 2>/dev/null || echo "0")
            local size_mb=$((file_size / 1024 / 1024))
            log "Downloaded file size: ${size_mb} MB"
            
            # Tailscale PKG should be at least 20MB
            if [ "$size_mb" -lt 10 ]; then
                log "Downloaded file appears too small (expected ~30MB+, got ${size_mb}MB)" "WARNING"
                rm -f "$DOWNLOAD_PATH" 2>/dev/null
                continue
            fi
            
            # Verify it's a valid PKG file
            if ! file "$DOWNLOAD_PATH" 2>/dev/null | grep -qi "xar\|zip\|package"; then
                log "Downloaded file does not appear to be a valid PKG file" "WARNING"
                rm -f "$DOWNLOAD_PATH" 2>/dev/null
                continue
            fi
            
            log "Successfully downloaded $url_name"
            return 0
        else
            log "Failed to download $url_name, trying next version..." "WARNING"
            rm -f "$DOWNLOAD_PATH" 2>/dev/null
        fi
    done
    
    log "Failed to download Tailscale PKG from all attempted URLs" "ERROR"
    return 1
}

install_tailscale() {
    log "Installing Tailscale PKG (SYSTEM-WIDE for ALL USERS)..."
    
    # Verify PKG file exists
    if [ ! -f "$DOWNLOAD_PATH" ]; then
        log "PKG file not found: $DOWNLOAD_PATH" "ERROR"
        return 1
    fi
    
    # Verify PKG is readable and valid
    if [ ! -r "$DOWNLOAD_PATH" ]; then
        log "PKG file is not readable: $DOWNLOAD_PATH" "ERROR"
        return 1
    fi
    
    log "PKG file verified: $DOWNLOAD_PATH"
    
    # Install the PKG using installer command
    # -pkg: path to package
    # -target: installation target (root volume = /)
    # -allowUntrusted: allow installation even if certificate is untrusted (may be needed)
    # -verboseR: show detailed installation output
    log "Running installer command..."
    
    local install_output
    local install_exit_code
    
    # Try with -allowUntrusted first
    log "Attempting installation with -allowUntrusted flag..."
    install_output=$(installer -pkg "$DOWNLOAD_PATH" -target / -allowUntrusted -verboseR 2>&1)
    install_exit_code=$?
    
    # Log full output for debugging
    echo "$install_output" | tee -a "$LOG_FILE"
    
    if [ $install_exit_code -eq 0 ]; then
        log "PKG installation completed successfully"
    else
        log "PKG installation failed with exit code: $install_exit_code" "WARNING"
        
        # Check if error is about scripts - this might be normal for some packages
        if echo "$install_output" | grep -qi "error.*script"; then
            log "Installation reported script errors, but checking if app was installed anyway..." "WARNING"
            # Continue to check if app was actually installed despite the error
        fi
        
        # Try without -allowUntrusted if that failed
        log "Retrying installation without -allowUntrusted flag..."
        install_output=$(installer -pkg "$DOWNLOAD_PATH" -target / -verboseR 2>&1)
        install_exit_code=$?
        
        echo "$install_output" | tee -a "$LOG_FILE"
        
        if [ $install_exit_code -eq 0 ]; then
            log "PKG installation completed successfully (second attempt)"
        else
            log "PKG installation failed on second attempt with exit code: $install_exit_code" "WARNING"
            # Don't return error yet - check if app was installed despite installer error
            log "Checking if Tailscale was installed despite installer error..." "INFO"
        fi
    fi
    
    # Wait a moment for installation to complete and filesystem to sync
    log "Waiting for installation to complete..."
    sleep 3
    
    # Verify the app was installed
    local max_wait=10
    local wait_count=0
    while [ $wait_count -lt $max_wait ] && [ ! -d "$INSTALL_PATH" ]; do
        wait_count=$((wait_count + 1))
        log "Waiting for Tailscale.app to appear... ($wait_count/$max_wait)"
        sleep 1
    done
    
    if [ ! -d "$INSTALL_PATH" ]; then
        log "Tailscale.app not found in /Applications after PKG installation" "ERROR"
        log "This may indicate the PKG installation did not complete properly"
        log "Checking /Applications contents..."
        ls -la /Applications/ | grep -i tailscale >> "$LOG_FILE" 2>/dev/null || true
        return 1
    fi
    
    log "Tailscale.app found at: $INSTALL_PATH"
    
    # Set proper ownership and permissions for ALL USERS access
    log "Setting ownership to root:wheel (system-wide access)..."
    if chown -R root:wheel "$INSTALL_PATH" 2>/dev/null; then
        log "Ownership set successfully"
    else
        log "Warning: Failed to set ownership (may already be correct)" "WARNING"
    fi
    
    log "Setting permissions to 755 (all users can execute)..."
    if chmod -R 755 "$INSTALL_PATH" 2>/dev/null; then
        log "Permissions set successfully"
    else
        log "Warning: Failed to set permissions (may already be correct)" "WARNING"
    fi
    
    # Clear quarantine attribute (allows app to run without Gatekeeper prompt)
    log "Clearing quarantine attribute..."
    if xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null; then
        log "Quarantine attribute cleared"
    else
        log "Quarantine attribute may not exist (this is OK)" "INFO"
    fi
    
    log "System-wide installation completed - Tailscale available to ALL USERS"
    log "NOTE: System Extension approval may be required in System Preferences > Security & Privacy"
    
    return 0
}

verify_installation() {
    log "Verifying Tailscale installation..."
    
    if [ ! -d "$INSTALL_PATH" ]; then
        log "Tailscale.app not found in /Applications" "ERROR"
        return 1
    fi
    
    # Verify bundle identifier
    local bundle_id
    bundle_id=$(defaults read "${INSTALL_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
    
    if [ "$bundle_id" != "$TAILSCALE_BUNDLE_ID" ] && [[ "$bundle_id" != *"tailscale"* ]]; then
        log "Bundle identifier mismatch: $bundle_id" "ERROR"
        return 1
    fi
    
    # Get version
    local version
    version=$(get_tailscale_version "$INSTALL_PATH")
    log "Installed Tailscale version: $version"
    
    # Verify code signature
    if codesign -v "$INSTALL_PATH" 2>/dev/null; then
        log "Code signature: Valid"
    else
        log "Code signature: Could not verify (may still work)" "WARNING"
    fi
    
    # Check if Tailscale daemon is installed
    if [ -f "/Library/LaunchDaemons/com.tailscale.tailscaled.plist" ]; then
        log "Tailscale daemon LaunchDaemon found"
    else
        log "Tailscale daemon LaunchDaemon not found (may be normal)" "WARNING"
    fi
    
    return 0
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

# Check macOS version compatibility (warning only - let Tailscale installer handle version check)
if ! check_macos_version; then
    log "macOS version check failed, but proceeding anyway" "WARNING"
    log "Tailscale installer will validate version requirements" "WARNING"
    log "Current macOS: $(get_macos_version), Required: $MIN_MACOS_VERSION" "WARNING"
    # Don't exit - let the installation proceed and Tailscale will handle it
fi

# Check if Tailscale is already installed (system-wide)
log "Checking for existing Tailscale installation in /Applications..."
if check_tailscale_installed; then
    local_version=$(get_tailscale_version "$INSTALL_PATH")
    log "Tailscale is already installed (system-wide)"
    log "Version: $local_version"
    log "Path: $INSTALL_PATH"
    log "Install Type: System-wide (all users)"
    log "=========================================="
    
    echo ""
    echo "=========================================="
    echo "Tailscale Installation Status"
    echo "=========================================="
    echo "Hostname: $(hostname)"
    echo ""
    write_summary "OK" "Tailscale already installed for ALL USERS (v${local_version})"
    echo "Path: $INSTALL_PATH"
    echo "Install Type: System-wide (/Applications)"
    echo ""
    echo "NOTE: If Tailscale is not working, check System Preferences > Security & Privacy"
    echo "      to ensure the System Extension is approved."
    
    exit $EXIT_SUCCESS
fi

log "Tailscale is not installed. Starting installation..."
log ""

# Download Tailscale PKG
if ! download_tailscale; then
    log "Download failed" "ERROR"
    write_summary "CRITICAL" "Failed to download Tailscale PKG"
    exit $EXIT_CRITICAL
fi

# Install Tailscale
if ! install_tailscale; then
    log "Installation failed" "ERROR"
    write_summary "CRITICAL" "Failed to install Tailscale"
    exit $EXIT_CRITICAL
fi

# Verify installation
if ! verify_installation; then
    log "Verification failed" "ERROR"
    write_summary "CRITICAL" "Tailscale installation verification failed"
    exit $EXIT_CRITICAL
fi

# Get final version info
final_version=$(get_tailscale_version "$INSTALL_PATH")

log ""
log "=========================================="
log "Installation completed successfully!"
log "=========================================="

echo ""
echo "=========================================="
echo "Tailscale Installation Complete (All Users)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo ""
write_summary "OK" "Tailscale installed for ALL USERS (v${final_version})"
echo "Path: $INSTALL_PATH"
echo "Version: $final_version"
echo "Install Type: System-wide (/Applications)"
echo "Ownership: root:wheel"
echo "Permissions: 755 (all users can execute)"
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. Users may need to approve the System Extension in:"
echo "   System Preferences > Security & Privacy > General"
echo "2. After approval, Tailscale will be ready to use"
echo "3. Users can sign in via the Tailscale app or command line"
echo ""
echo "NOTE: If Tailscale reports OS version incompatibility, the latest version"
echo "      may require a newer macOS. Check Tailscale's system requirements"
echo "      or consider using an older Tailscale version compatible with macOS 12.x"

exit $EXIT_SUCCESS
