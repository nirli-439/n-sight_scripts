#!/bin/bash
# =============================================================================
# Rename_Hostname_mac.sh - Rename macOS hostname
# =============================================================================
#
# SYNOPSIS:
#     Rename macOS hostname to a specified name.
#
# DESCRIPTION:
#     This script renames the macOS hostname by setting:
#     - ComputerName: The "friendly" name shown in Finder/System Preferences
#     - LocalHostName: The Bonjour name (used for .local)
#     - HostName: The network hostname
#     - NetBIOS name: The Windows sharing name
#     
#     The new hostname can be provided via:
#     1. Command line parameter: ./Rename_Hostname_mac.sh "HOSTNAME"
#     2. Environment variable: NEW_HOSTNAME (for N-Sight RMM)
#
#     Designed for N-Sight RMM deployment to rename macOS hostnames.
#
# EXIT CODES:
#     0    = Success (rename completed)
#     1001 = Warning (validation issue or minor problem)
#     1002 = Critical (rename failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Rename_Hostname_mac.sh "NEW-HOSTNAME"
#     Or:             bash /path/to/Rename_Hostname_mac.sh "NEW-HOSTNAME"   (run as root when required)
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Rename_Hostname_mac.sh" | sudo bash -s "NEW-HOSTNAME"
#     In N-Sight, pass NEW_HOSTNAME as a script parameter or environment variable.
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Administrator privileges (root or sudo)
#     Platform: macOS 10.13+ (High Sierra and later)
#
# =============================================================================

# Strict mode for better error handling
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Rename macOS Hostname"
readonly SCRIPT_VERSION="1.1"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/RenameHostname_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" | tee -a "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [ "$EUID" -ne 0 ] && [ "$(id -u)" -ne 0 ]; then
        log "This script requires administrator privileges!" "ERROR"
        echo "CRITICAL: Script requires administrator privileges"
        echo "Run with: sudo $0 \"HOSTNAME\""
        exit $EXIT_CRITICAL
    fi
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

get_macos_name() {
    sw_vers -productName 2>/dev/null || echo "macOS"
}

get_current_hostnames() {
    # Get current hostname values
    CURRENT_COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || echo "N/A")
    CURRENT_LOCAL_HOSTNAME=$(scutil --get LocalHostName 2>/dev/null || echo "N/A")
    CURRENT_HOST_NAME=$(scutil --get HostName 2>/dev/null || echo "N/A")
    CURRENT_HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
    CURRENT_NETBIOS_NAME=$(defaults read /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName 2>/dev/null || echo "N/A")
}

validate_hostname() {
    local hostname="$1"
    local errors=()
    
    # Check if hostname is empty
    if [ -z "$hostname" ]; then
        errors+=("Hostname cannot be empty")
        echo "${errors[@]}"
        return 1
    fi
    
    # Check length (1-63 characters for DNS compatibility)
    if [ ${#hostname} -lt 1 ] || [ ${#hostname} -gt 63 ]; then
        errors+=("Hostname must be between 1 and 63 characters (current: ${#hostname})")
    fi
    
    # Check for valid characters (alphanumeric, hyphens, and dots)
    if ! [[ "$hostname" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        errors+=("Hostname can only contain letters, numbers, hyphens, and dots")
    fi
    
    # Cannot start or end with hyphen or dot
    if [[ "$hostname" =~ ^[-.] ]] || [[ "$hostname" =~ [-.]$ ]]; then
        errors+=("Hostname cannot start or end with a hyphen or dot")
    fi
    
    # Cannot be all numbers
    if [[ "$hostname" =~ ^[0-9]+$ ]]; then
        errors+=("Hostname cannot be entirely numeric")
    fi
    
    # Check for consecutive dots or hyphens
    if [[ "$hostname" =~ \.\. ]] || [[ "$hostname" =~ -- ]]; then
        errors+=("Hostname cannot contain consecutive dots or hyphens")
    fi
    
    # Check for reserved names (basic check)
    local reserved_names=("localhost" "LOCALHOST" "local" "LOCAL")
    local hostname_upper
    hostname_upper=$(echo "$hostname" | tr '[:lower:]' '[:upper:]')
    
    for reserved in "${reserved_names[@]}"; do
        if [ "$hostname_upper" = "$reserved" ]; then
            errors+=("Hostname '$hostname' is a reserved name and cannot be used")
            break
        fi
    done
    
    if [ ${#errors[@]} -gt 0 ]; then
        printf '%s\n' "${errors[@]}"
        return 1
    fi
    
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "macOS Version: $(get_macos_name) $(get_macos_version)"
log "Build: $(sw_vers -buildVersion 2>/dev/null || echo 'Unknown')"
log "Execution Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log File: $LOG_FILE"
log "Running as user: $(whoami)"

# Check for root privileges
check_root

# Get current hostnames
get_current_hostnames

log "Current ComputerName: $CURRENT_COMPUTER_NAME"
log "Current LocalHostName: $CURRENT_LOCAL_HOSTNAME"
log "Current HostName: $CURRENT_HOST_NAME"
log "Current hostname (short): $CURRENT_HOSTNAME_SHORT"
log "Current NetBIOS name: $CURRENT_NETBIOS_NAME"

# Get the new hostname from parameter or environment variable
# Check environment variable first (for N-Sight RMM), then command line parameter
if [ -n "${NEW_HOSTNAME:-}" ]; then
    NEW_HOSTNAME="${NEW_HOSTNAME}"
elif [ -n "${1:-}" ]; then
    NEW_HOSTNAME="${1}"
else
    NEW_HOSTNAME=""
fi

# Clean up the hostname (trim whitespace, convert to uppercase for consistency)
NEW_HOSTNAME=$(echo "$NEW_HOSTNAME" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

if [ -z "$NEW_HOSTNAME" ]; then
    log "No new hostname specified!" "ERROR"
    log "Provide hostname via command line parameter or NEW_HOSTNAME environment variable" "ERROR"
    echo ""
    echo "CRITICAL: No new hostname specified"
    echo "Usage: $0 'NEW-HOSTNAME'"
    echo "   Or: Set NEW_HOSTNAME environment variable in N-Sight RMM"
    exit $EXIT_CRITICAL
fi

log "Target Hostname: $NEW_HOSTNAME"

# Prepare formatted LocalHostName for comparison
LOCAL_HOSTNAME_FORMATTED=$(echo "$NEW_HOSTNAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr '_' '-' | sed 's/\./-/g')

# Check if all hostname types are already aligned correctly
ALL_ALIGNED=true

if [ "$CURRENT_COMPUTER_NAME" != "$NEW_HOSTNAME" ]; then
    ALL_ALIGNED=false
    log "ComputerName needs update: '$CURRENT_COMPUTER_NAME' != '$NEW_HOSTNAME'" "INFO"
fi

if [ "$CURRENT_LOCAL_HOSTNAME" != "$LOCAL_HOSTNAME_FORMATTED" ]; then
    ALL_ALIGNED=false
    log "LocalHostName needs update: '$CURRENT_LOCAL_HOSTNAME' != '$LOCAL_HOSTNAME_FORMATTED'" "INFO"
fi

if [ "$CURRENT_HOST_NAME" = "N/A" ] || [ "$CURRENT_HOST_NAME" != "$NEW_HOSTNAME" ]; then
    ALL_ALIGNED=false
    if [ "$CURRENT_HOST_NAME" = "N/A" ]; then
        log "HostName is not set - will be set to '$NEW_HOSTNAME'" "INFO"
    else
        log "HostName needs update: '$CURRENT_HOST_NAME' != '$NEW_HOSTNAME'" "INFO"
    fi
fi

# NetBIOS name is optional - only check if it exists and doesn't match
if [ "$CURRENT_NETBIOS_NAME" != "N/A" ] && [ "$CURRENT_NETBIOS_NAME" != "$NEW_HOSTNAME" ]; then
    ALL_ALIGNED=false
    log "NetBIOS name needs update: '$CURRENT_NETBIOS_NAME' != '$NEW_HOSTNAME'" "INFO"
fi

# If all hostname types are already aligned, skip rename
if [ "$ALL_ALIGNED" = true ]; then
    log "All hostname types are already aligned to '$NEW_HOSTNAME' - no action needed" "INFO"
    echo ""
    echo "OK: All hostname types are already aligned to '$NEW_HOSTNAME'"
    echo "ComputerName: $CURRENT_COMPUTER_NAME"
    echo "LocalHostName: $CURRENT_LOCAL_HOSTNAME"
    echo "HostName: $CURRENT_HOST_NAME"
    echo "NetBIOS name: $CURRENT_NETBIOS_NAME"
    exit $EXIT_SUCCESS
fi

log "Hostname alignment needed - proceeding with rename..."

# Validate hostname
log "Validating hostname format..."
VALIDATION_ERRORS=$(validate_hostname "$NEW_HOSTNAME")
VALIDATION_RESULT=$?

if [ $VALIDATION_RESULT -ne 0 ]; then
    while IFS= read -r error; do
        log "Validation Error: $error" "ERROR"
    done <<< "$VALIDATION_ERRORS"
    
    echo ""
    echo "CRITICAL: Invalid hostname '$NEW_HOSTNAME'"
    while IFS= read -r error; do
        echo "  - $error"
    done <<< "$VALIDATION_ERRORS"
    exit $EXIT_CRITICAL
fi

log "Hostname validation passed"

# Perform the rename
log "=========================================="
log "Initiating hostname rename..."
log "From ComputerName: $CURRENT_COMPUTER_NAME"
log "To: $NEW_HOSTNAME"
log "=========================================="

RENAME_SUCCESS=true
RENAME_ERRORS=()

# Set ComputerName (friendly name)
log "Setting ComputerName..."
if scutil --set ComputerName "$NEW_HOSTNAME" 2>/dev/null; then
    log "ComputerName set successfully"
else
    log "Failed to set ComputerName" "ERROR"
    RENAME_SUCCESS=false
    RENAME_ERRORS+=("Failed to set ComputerName")
fi

# Set LocalHostName (Bonjour name - must be lowercase, no spaces, no special chars except hyphens)
# LOCAL_HOSTNAME_FORMATTED was already calculated above
log "Setting LocalHostName (formatted as: $LOCAL_HOSTNAME_FORMATTED)..."
if scutil --set LocalHostName "$LOCAL_HOSTNAME_FORMATTED" 2>/dev/null; then
    log "LocalHostName set successfully"
else
    log "Failed to set LocalHostName" "ERROR"
    RENAME_SUCCESS=false
    RENAME_ERRORS+=("Failed to set LocalHostName")
fi

# Set HostName (network hostname)
log "Setting HostName..."
if scutil --set HostName "$NEW_HOSTNAME" 2>/dev/null; then
    log "HostName set successfully"
else
    log "Failed to set HostName" "ERROR"
    RENAME_SUCCESS=false
    RENAME_ERRORS+=("Failed to set HostName")
fi

# Set NetBIOS name if possible (for Windows sharing)
log "Setting NetBIOS name..."
if defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName "$NEW_HOSTNAME" 2>/dev/null; then
    log "NetBIOS name set successfully"
else
    log "Warning: Could not set NetBIOS name (may not be critical)" "WARNING"
fi

# Verify the changes
log "Verifying hostname changes..."
VERIFY_COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || echo "N/A")
VERIFY_LOCAL_HOSTNAME=$(scutil --get LocalHostName 2>/dev/null || echo "N/A")
VERIFY_HOST_NAME=$(scutil --get HostName 2>/dev/null || echo "N/A")
VERIFY_NETBIOS_NAME=$(defaults read /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName 2>/dev/null || echo "N/A")

log "Verified ComputerName: $VERIFY_COMPUTER_NAME"
log "Verified LocalHostName: $VERIFY_LOCAL_HOSTNAME"
log "Verified HostName: $VERIFY_HOST_NAME"
log "Verified NetBIOS name: $VERIFY_NETBIOS_NAME"

if [ "$RENAME_SUCCESS" = false ]; then
    log "Rename completed with errors" "ERROR"
    echo ""
    echo "CRITICAL: Failed to rename hostname completely"
    echo "Errors encountered:"
    for error in "${RENAME_ERRORS[@]}"; do
        echo "  - $error"
    done
    echo ""
    echo "Current status:"
    echo "  ComputerName: $VERIFY_COMPUTER_NAME"
    echo "  LocalHostName: $VERIFY_LOCAL_HOSTNAME"
    echo "  HostName: $VERIFY_HOST_NAME"
    echo "  NetBIOS name: $VERIFY_NETBIOS_NAME"
    exit $EXIT_CRITICAL
fi

# Check if verification matches expected values
VERIFICATION_PASSED=true

if [ "$VERIFY_COMPUTER_NAME" != "$NEW_HOSTNAME" ]; then
    log "Warning: ComputerName verification failed (expected: $NEW_HOSTNAME, got: $VERIFY_COMPUTER_NAME)" "WARNING"
    VERIFICATION_PASSED=false
fi

if [ "$VERIFY_LOCAL_HOSTNAME" != "$LOCAL_HOSTNAME_FORMATTED" ]; then
    log "Warning: LocalHostName verification failed (expected: $LOCAL_HOSTNAME_FORMATTED, got: $VERIFY_LOCAL_HOSTNAME)" "WARNING"
    VERIFICATION_PASSED=false
fi

if [ "$VERIFY_HOST_NAME" != "$NEW_HOSTNAME" ]; then
    log "Warning: HostName verification failed (expected: $NEW_HOSTNAME, got: $VERIFY_HOST_NAME)" "WARNING"
    VERIFICATION_PASSED=false
fi

# Note: NetBIOS name verification is optional (may not be set on all systems)
if [ "$VERIFY_NETBIOS_NAME" != "N/A" ] && [ "$VERIFY_NETBIOS_NAME" != "$NEW_HOSTNAME" ]; then
    log "Warning: NetBIOS name verification failed (expected: $NEW_HOSTNAME, got: $VERIFY_NETBIOS_NAME)" "WARNING"
    # Don't fail verification for NetBIOS as it's optional
fi

log "=========================================="
log "Script completed!"
log "=========================================="

if [ "$VERIFICATION_PASSED" = false ]; then
    echo ""
    echo "WARNING: Hostname rename completed but verification shows mismatches"
    echo "Expected: $NEW_HOSTNAME"
    echo "Current values:"
    echo "  ComputerName: $VERIFY_COMPUTER_NAME"
    echo "  LocalHostName: $VERIFY_LOCAL_HOSTNAME"
    echo "  HostName: $VERIFY_HOST_NAME"
    echo "  NetBIOS name: $VERIFY_NETBIOS_NAME"
    echo ""
    echo "Note: Changes may require a logout/login or restart to fully take effect"
    exit $EXIT_WARNING
else
    echo ""
    echo "OK: Hostname successfully renamed to '$NEW_HOSTNAME'"
    echo "ComputerName: $VERIFY_COMPUTER_NAME"
    echo "LocalHostName: $VERIFY_LOCAL_HOSTNAME"
    echo "HostName: $VERIFY_HOST_NAME"
    echo "NetBIOS name: $VERIFY_NETBIOS_NAME"
    echo ""
    echo "Note: Some applications may require a logout/login or restart to see the new hostname"
    exit $EXIT_SUCCESS
fi
