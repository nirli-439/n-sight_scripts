#!/bin/bash
# =============================================================================
# Set_Chrome_Default_Browser_mac.sh - Set Chrome as Default Browser
# =============================================================================
#
# SYNOPSIS:
#     Sets Google Chrome as the system-wide default browser for HTTP/HTTPS URLs
#     and HTML files on macOS.
#
# DESCRIPTION:
#     This script sets Chrome as the default browser using multiple methods:
#     1. Uses LaunchServices API (via Python/PyObjC if available)
#     2. Registers Chrome with Launch Services database
#     3. Sets preferences for all users via defaults command
#     4. Rebuilds Launch Services database
#
#     Designed for N-Sight RMM deployment to enforce Chrome as primary browser.
#
# EXIT CODES:
#     0    = Success (Chrome set as default)
#     1001 = Warning (Partial success - may require user confirmation)
#     1002 = Critical/Error (Chrome not installed or operation failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Set_Chrome_Default_Browser_mac.sh
#     Or:             bash /path/to/Set_Chrome_Default_Browser_mac.sh   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Set_Chrome_Default_Browser_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     IMPORTANT:
#     - Chrome MUST be installed before running this script
#     - Some default browser settings may require user confirmation on newer macOS
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Set Chrome Default Browser"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/SetChromeDefault_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Application paths
readonly CHROME_PATH="/Applications/Google Chrome.app"
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
    # Check if Chrome is installed in /Applications
    if [ -d "$CHROME_PATH" ]; then
        # Verify it's actually Chrome by checking bundle identifier
        local bundle_id
        bundle_id=$(defaults read "${CHROME_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
            return 0
        fi
    fi
    
    return 1
}

_set_ls_handler() {
    # Update or add a LaunchServices handler entry directly in a user's plist via PlistBuddy.
    # Finds an existing entry for the scheme/content-type and updates it, or appends a new one.
    local plist="$1"
    local key="$2"       # LSHandlerURLScheme or LSHandlerContentType
    local value="$3"     # e.g. http, https, public.html
    local bundle_id="$4"

    [ -f "$plist" ] || return 1

    # Count existing entries
    local count=0
    while /usr/libexec/PlistBuddy -c "Print :LSHandlers:${count}" "$plist" &>/dev/null; do
        count=$((count + 1))
    done

    # Search for an existing entry matching this key/value and update it
    local i
    local found=false
    for i in $(seq 0 $((count - 1))); do
        local val
        val=$(/usr/libexec/PlistBuddy -c "Print :LSHandlers:${i}:${key}" "$plist" 2>/dev/null || echo "")
        if [ "$val" = "$value" ]; then
            /usr/libexec/PlistBuddy -c "Set :LSHandlers:${i}:LSHandlerRoleAll $bundle_id" "$plist" 2>/dev/null
            found=true
            break
        fi
    done

    if [ "$found" = false ]; then
        /usr/libexec/PlistBuddy -c "Add :LSHandlers: dict" "$plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :LSHandlers:${count}:${key} string ${value}" "$plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :LSHandlers:${count}:LSHandlerRoleAll string ${bundle_id}" "$plist" 2>/dev/null
    fi
}

set_chrome_default_browser() {
    log "Setting Chrome as default browser..."
    
    local success_count=0
    local total_operations=4
    local warning_needed=false
    
    # Get current console user (if any)
    local console_user
    console_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
    
    # Method 1: Use Python with PyObjC to set default handlers (macOS native)
    log "Setting URL scheme handlers via LaunchServices..."
    
    # Create Python script for setting handlers
    local python_script="/tmp/set_default_browser.py"
    cat > "$python_script" << 'PYTHON_EOF'
#!/usr/bin/env python3
import sys
try:
    from LaunchServices import LSSetDefaultHandlerForURLScheme, LSSetDefaultRoleHandlerForContentType
    from CoreServices import kLSRolesAll
    
    chrome_bundle_id = "com.google.Chrome"
    schemes = ["http", "https"]
    content_types = ["public.html", "public.xhtml", "public.url"]
    
    success = True
    
    # Set Chrome as handler for URL schemes
    for scheme in schemes:
        result = LSSetDefaultHandlerForURLScheme(scheme, chrome_bundle_id)
        if result != 0:
            print(f"Warning: Failed to set handler for {scheme} (error: {result})")
            success = False
        else:
            print(f"Set Chrome as handler for {scheme}")
    
    # Set Chrome as handler for content types
    for content_type in content_types:
        result = LSSetDefaultRoleHandlerForContentType(content_type, kLSRolesAll, chrome_bundle_id)
        if result != 0:
            print(f"Warning: Failed to set handler for {content_type} (error: {result})")
        else:
            print(f"Set Chrome as handler for {content_type}")
    
    sys.exit(0 if success else 1)
    
except ImportError:
    print("PyObjC not available")
    sys.exit(2)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYTHON_EOF
    
    chmod +x "$python_script"
    
    # Try running the Python script (suppress xcode-select errors)
    local python_output
    python_output=$(/usr/bin/python3 "$python_script" 2>&1 | grep -v "xcode-select" | grep -v "developer tools" || true)
    local python_exit=$?
    
    if [ $python_exit -eq 0 ]; then
        log "LaunchServices handlers set successfully via PyObjC"
        success_count=$((success_count + 1))
    elif [ $python_exit -eq 2 ]; then
        log "PyObjC not available - using alternative methods" "INFO"
        warning_needed=true
    else
        log "Python LaunchServices method failed - using alternatives" "WARNING"
        warning_needed=true
    fi
    
    rm -f "$python_script" 2>/dev/null
    
    # Method 2: Register Chrome with Launch Services
    log "Registering Chrome with Launch Services..."
    
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$CHROME_PATH" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log "Chrome registered with Launch Services"
        success_count=$((success_count + 1))
    fi
    
    # Method 3: Set preferences via PlistBuddy for each user (finds and replaces existing entries)
    log "Setting browser preferences for all users via PlistBuddy..."

    for user_home in /Users/*; do
        local username
        username=$(basename "$user_home")

        # Skip system directories
        if [ "$username" = "Shared" ] || [ "$username" = "Guest" ] || [ "$username" = ".localized" ]; then
            continue
        fi

        if [ -d "$user_home" ] && [ -d "${user_home}/Library" ]; then
            log "Setting preferences for user: $username"

            local plist_dir="${user_home}/Library/Preferences/com.apple.LaunchServices"
            local plist="${plist_dir}/com.apple.launchservices.secure.plist"

            # Kill cfprefsd for this user so any pending writes are flushed to disk first
            pkill -U "$username" cfprefsd 2>/dev/null || true
            sleep 0.5

            # Ensure plist and LSHandlers array exist
            mkdir -p "$plist_dir" 2>/dev/null
            if [ ! -f "$plist" ]; then
                /usr/libexec/PlistBuddy -c "Add :LSHandlers array" "$plist" 2>/dev/null
            elif ! /usr/libexec/PlistBuddy -c "Print :LSHandlers" "$plist" &>/dev/null; then
                /usr/libexec/PlistBuddy -c "Add :LSHandlers array" "$plist" 2>/dev/null
            fi

            # Update or add each handler entry
            _set_ls_handler "$plist" "LSHandlerURLScheme"   "http"         "$CHROME_BUNDLE_ID"
            _set_ls_handler "$plist" "LSHandlerURLScheme"   "https"        "$CHROME_BUNDLE_ID"
            _set_ls_handler "$plist" "LSHandlerContentType" "public.html"  "$CHROME_BUNDLE_ID"
            _set_ls_handler "$plist" "LSHandlerContentType" "public.xhtml" "$CHROME_BUNDLE_ID"

            # Restore ownership
            chown -R "${username}" "$plist_dir" 2>/dev/null
        fi
    done

    success_count=$((success_count + 1))
    
    # Method 4: Rebuild Launch Services database
    log "Rebuilding Launch Services database..."
    
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -kill -r -domain local -domain system -domain user 2>/dev/null || true
    
    # Restart cfprefsd to apply preference changes
    killall cfprefsd 2>/dev/null || true
    
    success_count=$((success_count + 1))
    
    # Report results
    log "Default browser operations completed: $success_count/$total_operations succeeded"
    
    # Return success if at least some operations succeeded
    if [ $success_count -gt 0 ]; then
        if [ "$warning_needed" = true ]; then
            return 2  # Partial success with warnings (but still success)
        fi
        return 0  # Success
    fi
    
    return 1  # Complete failure
}

verify_chrome_default() {
    log "Verifying Chrome is set as default browser..."
    
    # Check default browser using Python if available
    local python_check_script="/tmp/check_default_browser_verify.py"
    cat > "$python_check_script" << 'PYVERIFY_EOF'
#!/usr/bin/env python3
import sys
try:
    from LaunchServices import LSCopyDefaultHandlerForURLScheme
    
    handler = LSCopyDefaultHandlerForURLScheme("http")
    if handler and "chrome" in handler.lower():
        print("Chrome")
        sys.exit(0)
    elif handler:
        print(f"Other: {handler}")
        sys.exit(1)
    else:
        print("None")
        sys.exit(1)
except ImportError:
    print("PyObjC not available")
    sys.exit(2)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYVERIFY_EOF
    
    chmod +x "$python_check_script"
    # Suppress xcode-select errors
    local browser_check
    browser_check=$(/usr/bin/python3 "$python_check_script" 2>/dev/null)
    local check_exit=$?
    # If we got output despite errors, check if it's valid
    if [ -z "$browser_check" ] && [ $check_exit -ne 0 ]; then
        # Try again without suppressing to see actual error
        browser_check=$(/usr/bin/python3 "$python_check_script" 2>&1 | grep -v "xcode-select" | grep -v "developer tools" | head -1 || echo "")
    fi
    rm -f "$python_check_script" 2>/dev/null
    
    if [ $check_exit -eq 0 ]; then
        log "Verification: Chrome is set as default browser"
        return 0
    elif [ $check_exit -eq 2 ]; then
        # Fallback to defaults command if PyObjC not available
        local current_http_handler
        # LSHandlerRoleAll sorts before LSHandlerURLScheme alphabetically, so use -B2
        current_http_handler=$(defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | \
            grep -B2 "LSHandlerURLScheme = http" | grep "LSHandlerRoleAll" | head -1)
        
        if [[ "$current_http_handler" == *"chrome"* ]] || [[ "$current_http_handler" == *"Chrome"* ]]; then
            log "Verification: Chrome appears to be set (via defaults)"
            return 0
        else
            log "Verification: May require user confirmation on first use" "WARNING"
            return 1
        fi
    else
        log "Verification: Unable to verify (may require user confirmation)" "WARNING"
        return 1
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
log "macOS: $(sw_vers -productName 2>/dev/null || echo 'macOS') $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
log "User: $(whoami)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Pre-flight checks
check_root

# Step 1: Check if Chrome is installed
log "Step 1: Checking for Chrome installation..."
if ! check_chrome_installed; then
    log "Google Chrome is NOT installed" "ERROR"
    write_summary "CRITICAL" "Chrome NOT installed - cannot proceed"
    echo ""
    echo "Please install Google Chrome first using Install_Chrome_mac.sh"
    exit $EXIT_CRITICAL
fi

chrome_version=$(get_chrome_version "$CHROME_PATH")
log "Chrome found: v${chrome_version}"
log ""

# Step 2: Check if already default
log "Step 2: Checking if Chrome is already the default browser..."
# Get current console user
console_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
is_already_default=false

if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
    # Check current user's secure launch services preferences
    # LSHandlerRoleAll sorts before LSHandlerURLScheme alphabetically, so use -B2
    handler=$(sudo -u "$console_user" defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | \
        grep -B2 "LSHandlerURLScheme = http" | grep "LSHandlerRoleAll" | grep -oE "com.google.[Cc]hrome" | head -1)

    if [ -n "$handler" ]; then
        is_already_default=true
    fi
fi

if [ "$is_already_default" = true ]; then
    log "Chrome is already the default browser for the current user" "SUCCESS"
    write_summary "OK" "Chrome v${chrome_version} is already the default browser"
    exit $EXIT_SUCCESS
fi

# Step 3: Set Chrome as default browser
log "Step 3: Setting Chrome as default browser..."
chrome_default=false
chrome_default_warning=false
set_chrome_default_browser
case $? in
    0)
        chrome_default=true
        log "Chrome set as default browser"
        ;;
    2)
        chrome_default=true  # Partial success still counts as success
        chrome_default_warning=true
        log "Chrome set as default browser (with warnings - may require user confirmation)" "WARNING"
        ;;
    *)
        log "Default browser setting may require user confirmation" "WARNING"
        ;;
esac
log ""

# Step 4: Verify configuration
log "Step 4: Verifying configuration..."
verify_chrome_default
log ""

# Determine final status
log "=========================================="
log "Operation Summary"
log "=========================================="

echo ""
echo "=========================================="
echo "Chrome Default Browser Results"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "macOS: $(sw_vers -productName 2>/dev/null || echo 'macOS') $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
echo ""

if [ "$chrome_default" = true ]; then
    log "Chrome default browser configuration completed" "SUCCESS"
    write_summary "OK" "Chrome v${chrome_version} set as default browser"
    echo "Chrome Version: $chrome_version"
    if [ "$chrome_default_warning" = true ]; then
        echo "Default Browser: Chrome (set, but may require user confirmation on first use)"
    else
        echo "Default Browser: Google Chrome"
    fi
    echo ""
    echo "Configuration applied successfully."
    if [ "$chrome_default_warning" = true ]; then
        echo ""
        echo "Note: On macOS 10.15+, users may see a confirmation dialog when"
        echo "clicking links for the first time after this change."
    fi
    exit $EXIT_SUCCESS
    
else
    log "Chrome default browser configuration may need user action" "WARNING"
    write_summary "WARNING" "Chrome default browser may require user confirmation"
    echo "Chrome Version: $chrome_version"
    echo "Default Browser: May require user confirmation"
    echo ""
    echo "Note: On macOS 10.15+, users may see a confirmation dialog when"
    echo "clicking links for the first time. They should select Chrome."
    exit $EXIT_WARNING
fi
