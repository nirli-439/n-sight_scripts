#!/bin/bash
# Check_Hostname_Inventory_mac.sh - Check if hostname starts with "IA" (Inventory Asset naming)
# For N-Sight RMM deployment. macOS equivalent of Windows Check_ComputerName_Inventory.ps1
#
# SYNOPSIS:
#   Checks for proper hostname naming convention compliance on macOS.
#
# DESCRIPTION:
#   This monitoring script checks if the hostname follows the inventory
#   naming convention (starts with "IA" prefix).
#   Checks all macOS hostname types: ComputerName, LocalHostName, HostName.
#   Reports hostname details for inventory tracking.
#   Designed for N-Sight RMM monitoring checks.
#
# EXIT CODES:
#   0    = OK (Hostname starts with IA)
#   1002 = CRITICAL (Hostname does NOT start with IA)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Hostname_Inventory_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Hostname_Inventory_mac.sh" | sudo bash
#
# NOTES:
#   Author: IT Admin
#   Version: 1.0
#   Platform: macOS 10.13+ (High Sierra and later)

# ============================================================================
# CONFIGURATION
# ============================================================================
REQUIRED_PREFIX="IA"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/HostnameCheck_$(date +%Y%m%d_%H%M%S).log"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" | tee -a "$LOG_FILE" 2>/dev/null
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

get_macos_name() {
    sw_vers -productName 2>/dev/null || echo "macOS"
}

get_hostname_info() {
    # macOS has multiple hostname types
    # ComputerName: The "friendly" name shown in Finder/System Preferences
    # LocalHostName: The Bonjour name (used for .local)
    # HostName: The network hostname
    
    COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || echo "N/A")
    LOCAL_HOSTNAME=$(scutil --get LocalHostName 2>/dev/null || echo "N/A")
    HOST_NAME=$(scutil --get HostName 2>/dev/null || hostname)
    HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
}

check_prefix() {
    local hostname="$1"
    local prefix="$2"
    
    # Case-insensitive check if hostname starts with prefix
    # Using tr for macOS compatibility (bash on macOS may be older)
    local hostname_upper
    local prefix_upper
    hostname_upper=$(echo "$hostname" | tr '[:lower:]' '[:upper:]')
    prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    if [[ "$hostname_upper" == "$prefix_upper"* ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Ensure log directory exists (may fail without root, that's OK)
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "Hostname Inventory Check"
log "=========================================="
log "macOS Version: $(get_macos_name) $(get_macos_version)"
log "Build: $(sw_vers -buildVersion 2>/dev/null || echo 'Unknown')"
log "Check Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Required Prefix: $REQUIRED_PREFIX"
log "Log File: $LOG_FILE"
log "Running as user: $(whoami)"

# Get hostname information
get_hostname_info

log ""
log "ComputerName: $COMPUTER_NAME"
log "LocalHostName: $LOCAL_HOSTNAME"
log "HostName: $HOST_NAME"
log "Hostname (short): $HOSTNAME_SHORT"

echo ""
echo "=========================================="
echo "Hostname Inventory Check"
echo "=========================================="
echo "macOS: $(get_macos_name) $(get_macos_version)"
echo ""

# Primary check is on ComputerName as it's the main identifier in macOS
# But we'll also display all hostname types for clarity
PRIMARY_HOSTNAME="$COMPUTER_NAME"

# Fallback to LocalHostName if ComputerName is not set
if [ "$PRIMARY_HOSTNAME" = "N/A" ] || [ -z "$PRIMARY_HOSTNAME" ]; then
    PRIMARY_HOSTNAME="$LOCAL_HOSTNAME"
fi

# Fallback to hostname command if still not available
if [ "$PRIMARY_HOSTNAME" = "N/A" ] || [ -z "$PRIMARY_HOSTNAME" ]; then
    PRIMARY_HOSTNAME="$HOSTNAME_SHORT"
fi

log "Primary hostname for check: $PRIMARY_HOSTNAME"

# Check if hostname starts with required prefix
if check_prefix "$PRIMARY_HOSTNAME" "$REQUIRED_PREFIX"; then
    log "Hostname Status: COMPLIANT"
    log "=========================================="
    
    echo "OK: Hostname complies with inventory naming convention"
    echo "ComputerName: $COMPUTER_NAME"
    echo "LocalHostName: $LOCAL_HOSTNAME"
    echo "HostName: $HOST_NAME"
    echo "Naming Convention: Starts with '$REQUIRED_PREFIX'"
    
    exit 0
else
    log "Hostname Status: NON-COMPLIANT" "WARNING"
    log "Expected prefix: $REQUIRED_PREFIX" "WARNING"
    log "=========================================="
    
    echo "CRITICAL: Hostname does NOT comply with inventory naming convention"
    echo "ComputerName: $COMPUTER_NAME"
    echo "LocalHostName: $LOCAL_HOSTNAME"
    echo "HostName: $HOST_NAME"
    echo "Required: Hostname must start with '$REQUIRED_PREFIX'"
    echo ""
    echo "To rename, use: sudo scutil --set ComputerName 'IA-NewName'"
    
    exit 1002
fi
