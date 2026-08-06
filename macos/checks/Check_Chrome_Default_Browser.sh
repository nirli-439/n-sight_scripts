#!/usr/bin/env bash
# =============================================================================
# Check_Chrome_Default_Browser.sh - Verify Chrome is the default browser
# =============================================================================
#
# SYNOPSIS:
#     Checks if Google Chrome is configured as the system default browser on macOS.
#     Verifies URL scheme handlers and file type associations.
#
# DESCRIPTION:
#     This monitoring script performs the following checks:
#     1. Verifies Chrome is installed
#     2. Checks if Chrome is set as handler for http:// and https:// URLs
#     3. Checks if Chrome is set as handler for HTML files
#     4. Verifies Chrome bundle is accessible
#     
#     Designed for N-Sight RMM 24x7 monitoring with configurable check intervals.
#     Can trigger remediation via Disable_Safari_Default_Chrome_mac.sh when it fails.
#
# EXIT CODES:
#     0    = Success (Chrome is the default browser)
#     1001 = Warning (Chrome partially set as default)
#     1002 = Critical/Error (Chrome not set as default or not installed)
#
# EXECUTION:
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Chrome_Default_Browser.sh" | sudo bash
#     macOS: sudo bash /path/to/Check_Chrome_Default_Browser.sh
#     Or:    bash /path/to/Check_Chrome_Default_Browser.sh (as root when required)
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: No special privileges (read-only check), but sudo recommended
#     Platform: macOS 10.15+ (Catalina and later)
#     
#     N-Sight Usage:
#     - Deploy as a 24x7 check with 30-60 minute interval
#     - Can trigger remediation via Disable_Safari_Default_Chrome_mac.sh
#     - Exit code 1002 triggers CRITICAL in N-Sight dashboard
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Chrome Default Browser"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/CheckChromeDefault_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Application paths
readonly CHROME_PATH="/Applications/Google Chrome.app"
readonly SAFARI_PATH="/Applications/Safari.app"
readonly CHROME_BUNDLE_ID="com.google.Chrome"

# Marker file to track Safari disabled status
readonly SAFARI_DISABLED_MARKER="/var/db/.safari_disabled_by_policy"

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

check_safari_exists() {
    # Check if Safari exists (it should on all macOS systems)
    if [ -d "$SAFARI_PATH" ]; then
        return 0
    fi
    return 1
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

check_url_scheme_handler() {
    # Check if Chrome is set as handler for a URL scheme
    local scheme="$1"
    local handler
    
    # Get current console user
    local console_user
    console_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
    
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
        # Check current user's secure launch services preferences
        # LSHandlerRoleAll sorts before LSHandlerURLScheme alphabetically, so use -B2 (look above)
        handler=$(sudo -u "$console_user" defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | \
            grep -B2 "LSHandlerURLScheme = $scheme" | grep "LSHandlerRoleAll" | grep -oE "com.google.[Cc]hrome" | head -1)

        if [ -n "$handler" ]; then
            return 0
        fi
    fi

    # Fallback: check global system preferences
    handler=$(defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | \
        grep -B2 "LSHandlerURLScheme = $scheme" | grep "LSHandlerRoleAll" | grep -oE "com.google.[Cc]hrome" | head -1)
    
    if [ -n "$handler" ]; then
        return 0
    fi
    
    # Final fallback: use lsregister dump (legacy method)
    handler=$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -dump 2>/dev/null | grep -A1 "uti: $scheme" | grep "bindings:" | grep -oE "com.google.[Cc]hrome" | head -1)
    
    if [ -n "$handler" ]; then
        return 0
    fi
    
    return 1
}

check_file_type_handler() {
    # Check if Chrome is set as handler for a file type
    local file_type="$1"
    local handler
    
    # Get current console user
    local console_user
    console_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
    
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
        # Check current user's preferences
        handler=$(sudo -u "$console_user" defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | \
            grep -A2 "LSHandlerContentType = \"$file_type\"" | grep "LSHandlerRoleAll" | grep -oE "com.google.[Cc]hrome" | head -1)
        
        if [ -n "$handler" ]; then
            return 0
        fi
    fi
    
    # Fallback to lsregister dump
    handler=$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -dump 2>/dev/null | grep -A1 "uti: $file_type" | grep "bindings:" | grep -oE "com.google.[Cc]hrome" | head -1)
    
    if [ -n "$handler" ] && [ -n "$(echo "$handler" | grep -i "chrome")" ]; then
        return 0
    fi
    
    return 1
}

check_chrome_is_default_browser() {
    # Check using Python with LaunchServices if available
    local python_script="/tmp/check_default_browser.py"
    
    cat > "$python_script" << 'PYTHON_EOF'
#!/usr/bin/env python3
import sys
try:
    from LaunchServices import LSCopyDefaultHandlerForURLScheme
    
    chrome_bundle = "com.google.Chrome"
    schemes = ["http", "https"]
    
    all_chrome = True
    for scheme in schemes:
        handler = LSCopyDefaultHandlerForURLScheme(scheme)
        if handler != chrome_bundle:
            print(f"{scheme}: {handler if handler else 'None'}")
            all_chrome = False
        else:
            print(f"{scheme}: Chrome")
    
    sys.exit(0 if all_chrome else 1)
    
except ImportError:
    print("PyObjC not available")
    sys.exit(2)
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYTHON_EOF
    
    chmod +x "$python_script"
    
    # Suppress stderr to avoid xcode-select noise when run headless (e.g. N-Sight, SSH, no GUI)
    if /usr/bin/python3 "$python_script" 2>/dev/null | tee -a "$LOG_FILE"; then
        rm -f "$python_script" 2>/dev/null
        return 0
    fi
    
    rm -f "$python_script" 2>/dev/null
    return 1
}

is_safari_disabled() {
    # Check if Safari has been previously disabled by the policy script
    if [ -f "$SAFARI_DISABLED_MARKER" ]; then
        # Also verify Safari is actually restricted
        if [ ! -x "${SAFARI_PATH}/Contents/MacOS/Safari" ]; then
            return 0
        fi
    fi
    return 1
}

verify_safari_disabled() {
    # Wrapper for compatibility
    is_safari_disabled
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
log "macOS: $(get_macos_name) $(get_macos_version)"
log "Kernel: $(uname -r)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

# Step 1: Check if Chrome is installed
log "Step 1: Checking Chrome installation..."
if ! check_chrome_installed; then
    log "Chrome is NOT installed" "ERROR"
    write_summary "CRITICAL" "Chrome is not installed on this computer"
    echo "Install Chrome using Install_Chrome_mac.sh"
    exit $EXIT_CRITICAL
fi

chrome_version=$(get_chrome_version "$CHROME_PATH")
log "Chrome found: v${chrome_version}"
log ""

# Step 2: Check URL scheme handlers
log "Step 2: Checking URL scheme handlers..."
http_ok=false
https_ok=false

if check_url_scheme_handler "http"; then
    log "http:// handler is set to Chrome" "SUCCESS"
    http_ok=true
else
    log "http:// handler is NOT set to Chrome" "ERROR"
fi

if check_url_scheme_handler "https"; then
    log "https:// handler is set to Chrome" "SUCCESS"
    https_ok=true
else
    log "https:// handler is NOT set to Chrome" "ERROR"
fi
log ""

# Step 3: Check file type handlers
log "Step 3: Checking file type handlers..."
html_ok=false

if check_file_type_handler "public.html"; then
    log "HTML files handler is set to Chrome" "SUCCESS"
    html_ok=true
else
    log "HTML files handler is NOT set to Chrome" "ERROR"
fi
log ""

# Step 4: Verify using Python LaunchServices if available (optional; may be inconclusive when run headless)
log "Step 4: Verifying default browser with LaunchServices..."
python_verify=false

if check_chrome_is_default_browser 2>/dev/null; then
    log "LaunchServices confirms Chrome is default browser" "SUCCESS"
    python_verify=true
else
    log "LaunchServices verification inconclusive" "WARNING"
fi
log ""

# Determine final status
log "=========================================="
log "Check Summary"
log "=========================================="

if [ "$http_ok" = true ] && [ "$https_ok" = true ] && [ "$html_ok" = true ]; then
    log "Chrome is properly configured as default browser" "SUCCESS"
    write_summary "OK" "Chrome v${chrome_version} is the default browser"
    echo "HTTP Handler: Configured"
    echo "HTTPS Handler: Configured"
    echo "HTML Handler: Configured"
    exit $EXIT_SUCCESS
    
elif [ "$http_ok" = true ] || [ "$https_ok" = true ] || [ "$html_ok" = true ]; then
    log "Chrome is partially configured as default browser (WARNING)" "WARN"
    write_summary "WARNING" "Chrome is partially set as default - some handlers may need configuration"
    echo "HTTP Handler: $([ "$http_ok" = true ] && echo "✓ Configured" || echo "✗ Not configured")"
    echo "HTTPS Handler: $([ "$https_ok" = true ] && echo "✓ Configured" || echo "✗ Not configured")"
    echo "HTML Handler: $([ "$html_ok" = true ] && echo "✓ Configured" || echo "✗ Not configured")"
    echo ""
    echo "Run Set_Chrome_Default_Browser_mac.sh to attempt configuration"
    exit $EXIT_WARNING
    
else
    log "Chrome is NOT the default browser (CRITICAL)" "ERROR"
    write_summary "CRITICAL" "Chrome is NOT the default browser"
    echo "HTTP Handler: Not configured"
    echo "HTTPS Handler: Not configured"
    echo "HTML Handler: Not configured"
    echo ""
    echo "Run Set_Chrome_Default_Browser_mac.sh to set Chrome as default"
    exit $EXIT_CRITICAL
fi
