#!/bin/bash
# =============================================================================
# Check_Safari_Default_Browser.sh - Check if Safari is the Default Browser
# =============================================================================
#
# SYNOPSIS:
#     Checks if Safari is set as the default browser on macOS.
#     Designed to trigger remediation if Safari is still active/default.
#
# DESCRIPTION:
#     This monitoring script checks:
#     1. If Safari is the default HTTP/HTTPS handler
#     2. If Safari is still executable (not disabled by policy)
#     3. If Chrome is properly set as the default browser
#
#     The check FAILS (triggers remediation) when:
#     - Safari is the default browser for HTTP/HTTPS URLs
#     - Safari is still executable and not disabled
#     - Chrome is NOT the default browser (if installed)
#
#     The check PASSES when:
#     - Chrome is the default browser
#     - Safari is disabled (not executable)
#
#     Designed for N-Sight RMM monitoring checks on macOS.
#     Pair with Disable_Safari_Default_Chrome_mac.sh for remediation.
#
# EXIT CODES:
#     0    = OK (Chrome is default, Safari is disabled)
#     1001 = WARNING (Chrome is default but Safari still accessible)
#     1002 = CRITICAL (Safari is default browser - needs remediation)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Safari_Default_Browser.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Safari_Default_Browser.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: No special privileges for check (runs as any user)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Usage:
#     - Deploy as 24x7 Check
#     - Set Disable_Safari_Default_Chrome_mac.sh as remediation task
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Check Safari Default Browser"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/SafariDefaultCheck_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Application paths and bundle IDs
readonly SAFARI_PATH="/Applications/Safari.app"
readonly SAFARI_BINARY="${SAFARI_PATH}/Contents/MacOS/Safari"
readonly SAFARI_BUNDLE_ID="com.apple.Safari"
readonly CHROME_PATH="/Applications/Google Chrome.app"
readonly CHROME_BUNDLE_ID="com.google.Chrome"

# Policy marker file (created by remediation script)
readonly SAFARI_DISABLED_MARKER="/var/db/.safari_disabled_by_policy"

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

check_chrome_installed() {
    # Check if Chrome is installed in /Applications
    if [ -d "$CHROME_PATH" ]; then
        local bundle_id
        bundle_id=$(defaults read "${CHROME_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        
        if [ "$bundle_id" = "$CHROME_BUNDLE_ID" ] || [[ "$bundle_id" == *"Chrome"* ]]; then
            return 0
        fi
    fi
    return 1
}

get_chrome_version() {
    if [ -d "$CHROME_PATH" ]; then
        defaults read "${CHROME_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown"
    else
        echo "Not installed"
    fi
}

is_safari_executable() {
    # Check if Safari binary is executable
    if [ -x "$SAFARI_BINARY" ]; then
        return 0  # Safari is executable
    fi
    return 1  # Safari is not executable (disabled)
}

is_safari_disabled_by_policy() {
    # Check if Safari was disabled by our remediation script
    if [ -f "$SAFARI_DISABLED_MARKER" ]; then
        return 0  # Policy marker exists
    fi
    return 1
}

get_default_http_handler() {
    # Get the default handler for HTTP URLs
    # Uses Python to query LaunchServices
    local handler
    handler=$(/usr/bin/python3 - << 'PYTHON_EOF' 2>/dev/null
try:
    from LaunchServices import LSCopyDefaultHandlerForURLScheme
    from CoreFoundation import CFStringRef
    
    http_handler = LSCopyDefaultHandlerForURLScheme("http")
    if http_handler:
        print(str(http_handler).lower())
    else:
        print("unknown")
except Exception as e:
    print("error")
PYTHON_EOF
)
    echo "$handler"
}

get_default_https_handler() {
    # Get the default handler for HTTPS URLs
    local handler
    handler=$(/usr/bin/python3 - << 'PYTHON_EOF' 2>/dev/null
try:
    from LaunchServices import LSCopyDefaultHandlerForURLScheme
    from CoreFoundation import CFStringRef
    
    https_handler = LSCopyDefaultHandlerForURLScheme("https")
    if https_handler:
        print(str(https_handler).lower())
    else:
        print("unknown")
except Exception as e:
    print("error")
PYTHON_EOF
)
    echo "$handler"
}

check_default_browser_via_defaults() {
    # Alternative method: Check LSHandlers via defaults command
    # Returns: safari, chrome, or unknown
    
    local ls_handlers
    ls_handlers=$(defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null)
    
    if [ -z "$ls_handlers" ]; then
        echo "unknown"
        return
    fi
    
    # Check for http handler
    local http_handler
    http_handler=$(echo "$ls_handlers" | grep -A2 "LSHandlerURLScheme = http" | grep "LSHandlerRoleAll" | head -1 | tr -d ' ";')
    
    if [[ "$http_handler" == *"safari"* ]] || [[ "$http_handler" == *"Safari"* ]]; then
        echo "safari"
    elif [[ "$http_handler" == *"chrome"* ]] || [[ "$http_handler" == *"Chrome"* ]]; then
        echo "chrome"
    else
        # If no http handler set, Safari is typically the system default
        echo "system-default"
    fi
}

get_default_browser_name() {
    # Get a human-readable name for the default browser
    local http_handler
    http_handler=$(get_default_http_handler)
    
    case "$http_handler" in
        *safari*)
            echo "Safari"
            ;;
        *chrome*)
            echo "Google Chrome"
            ;;
        *firefox*)
            echo "Firefox"
            ;;
        *edge*)
            echo "Microsoft Edge"
            ;;
        *brave*)
            echo "Brave"
            ;;
        *arc*)
            echo "Arc"
            ;;
        "unknown"|"error"|"")
            echo "Unknown/System Default"
            ;;
        *)
            echo "$http_handler"
            ;;
    esac
}

is_safari_default_browser() {
    # Returns 0 if Safari is the default browser, 1 otherwise
    local http_handler
    http_handler=$(get_default_http_handler)
    
    # Check if Safari is explicitly set
    if [[ "$http_handler" == *"safari"* ]]; then
        return 0  # Safari IS the default
    fi
    
    # If handler is unknown or empty, Safari is usually the system default on macOS
    if [[ "$http_handler" == "unknown" ]] || [[ "$http_handler" == "error" ]] || [[ -z "$http_handler" ]]; then
        # Double check with alternative method
        local alt_check
        alt_check=$(check_default_browser_via_defaults)
        
        if [[ "$alt_check" == "safari" ]] || [[ "$alt_check" == "system-default" ]]; then
            return 0  # Safari is likely the default
        fi
    fi
    
    return 1  # Safari is NOT the default
}

is_chrome_default_browser() {
    # Returns 0 if Chrome is the default browser, 1 otherwise
    local http_handler
    http_handler=$(get_default_http_handler)
    
    if [[ "$http_handler" == *"chrome"* ]]; then
        return 0  # Chrome IS the default
    fi
    
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

# Initialize status tracking
SAFARI_STATUS="Unknown"
SAFARI_EXECUTABLE=false
SAFARI_IS_DEFAULT=false
CHROME_IS_DEFAULT=false
CHROME_INSTALLED=false
CHROME_VERSION=""
DEFAULT_BROWSER=""

# Check Chrome installation status
log "Checking Chrome installation..."
if check_chrome_installed; then
    CHROME_INSTALLED=true
    CHROME_VERSION=$(get_chrome_version)
    log "Chrome Status: Installed (v${CHROME_VERSION})"
else
    log "Chrome Status: NOT installed" "WARNING"
fi

# Check Safari executable status
log "Checking Safari status..."
if is_safari_executable; then
    SAFARI_EXECUTABLE=true
    SAFARI_STATUS="Enabled (executable)"
    log "Safari: Enabled (binary is executable)"
else
    SAFARI_STATUS="Disabled (not executable)"
    log "Safari: Disabled (binary is NOT executable)"
fi

# Check if Safari was disabled by policy
if is_safari_disabled_by_policy; then
    log "Safari: Policy marker found - disabled by remediation script"
    SAFARI_STATUS="${SAFARI_STATUS} - Policy applied"
fi

# Get default browser information
log "Checking default browser settings..."
DEFAULT_BROWSER=$(get_default_browser_name)
log "Default Browser: $DEFAULT_BROWSER"

# Check if Safari is the default
if is_safari_default_browser; then
    SAFARI_IS_DEFAULT=true
    log "Safari is the DEFAULT browser" "WARNING"
fi

# Check if Chrome is the default
if is_chrome_default_browser; then
    CHROME_IS_DEFAULT=true
    log "Chrome is the default browser"
fi

# Additional debug info
log ""
log "HTTP Handler: $(get_default_http_handler)"
log "HTTPS Handler: $(get_default_https_handler)"
log ""

# =============================================================================
# DETERMINE CHECK RESULT
# =============================================================================

log "=========================================="
log "Evaluating Check Results..."
log "=========================================="

echo ""
echo "=========================================="
echo "Safari Default Browser Check"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "macOS: $(get_macos_name) $(get_macos_version)"
echo ""

# Scenario 1: Safari is the default browser - CRITICAL (needs remediation)
if [ "$SAFARI_IS_DEFAULT" = true ]; then
    log "RESULT: CRITICAL - Safari is the default browser" "ERROR"
    
    write_summary "CRITICAL" "Safari is the default browser - remediation required"
    echo ""
    echo "Default Browser: $DEFAULT_BROWSER"
    echo "Safari Status: $SAFARI_STATUS"
    echo "Chrome Installed: $([ "$CHROME_INSTALLED" = true ] && echo "Yes (v${CHROME_VERSION})" || echo "No")"
    echo ""
    echo "Action Required: Safari is set as the default browser."
    echo "Remediation: Run Disable_Safari_Default_Chrome_mac.sh"
    
    exit $EXIT_CRITICAL
fi

# Scenario 2: Chrome is default and Safari is disabled - SUCCESS
if [ "$CHROME_IS_DEFAULT" = true ] && [ "$SAFARI_EXECUTABLE" = false ]; then
    log "RESULT: OK - Chrome is default, Safari is disabled" "SUCCESS"
    
    write_summary "OK" "Chrome v${CHROME_VERSION} is default browser, Safari disabled"
    echo ""
    echo "Default Browser: $DEFAULT_BROWSER"
    echo "Chrome Version: $CHROME_VERSION"
    echo "Safari Status: Disabled"
    echo ""
    echo "Browser policy is correctly configured."
    
    exit $EXIT_SUCCESS
fi

# Scenario 3: Chrome is default but Safari is still accessible - WARNING
if [ "$CHROME_IS_DEFAULT" = true ] && [ "$SAFARI_EXECUTABLE" = true ]; then
    log "RESULT: WARNING - Chrome is default but Safari still accessible" "WARNING"
    
    write_summary "WARNING" "Chrome is default but Safari is still accessible"
    echo ""
    echo "Default Browser: $DEFAULT_BROWSER"
    echo "Chrome Version: $CHROME_VERSION"
    echo "Safari Status: Still enabled (executable)"
    echo ""
    echo "Note: Chrome is set as default but Safari has not been disabled."
    echo "Users can still manually open Safari."
    echo "Consider running Disable_Safari_Default_Chrome_mac.sh for full enforcement."
    
    exit $EXIT_WARNING
fi

# Scenario 4: Chrome is not installed - CRITICAL
if [ "$CHROME_INSTALLED" = false ]; then
    log "RESULT: CRITICAL - Chrome is not installed" "ERROR"
    
    write_summary "CRITICAL" "Chrome NOT installed - cannot enforce browser policy"
    echo ""
    echo "Default Browser: $DEFAULT_BROWSER"
    echo "Safari Status: $SAFARI_STATUS"
    echo "Chrome Installed: No"
    echo ""
    echo "Chrome must be installed first before running browser policy remediation."
    echo "Remediation: Install Chrome using Install_Chrome_mac.sh first"
    
    exit $EXIT_CRITICAL
fi

# Scenario 5: Neither Safari nor Chrome is default (some other browser) - WARNING
log "RESULT: WARNING - Neither Safari nor Chrome is default browser" "WARNING"

write_summary "WARNING" "Default browser is $DEFAULT_BROWSER (not Chrome)"
echo ""
echo "Default Browser: $DEFAULT_BROWSER"
echo "Safari Status: $SAFARI_STATUS"
echo "Chrome Installed: Yes (v${CHROME_VERSION})"
echo ""
echo "A third-party browser is set as default."
echo "Run Disable_Safari_Default_Chrome_mac.sh to enforce Chrome as default."

exit $EXIT_WARNING
