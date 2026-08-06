#!/bin/bash
# Check_Hostname_Inventory.sh - Check if hostname starts with "IA" (Inventory Asset naming)
# For N-Sight RMM deployment
#
# SYNOPSIS:
#   Checks for proper hostname naming convention compliance.
#
# DESCRIPTION:
#   This monitoring script checks if the hostname follows the inventory
#   naming convention (starts with "IA" prefix).
#   Reports hostname details for inventory tracking.
#   Designed for N-Sight RMM monitoring checks.
#
#   Exit Codes:
#   - 0 = OK (Hostname starts with IA)
#   - 2 = CRITICAL (Hostname does NOT start with IA)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Hostname_Inventory_linux.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/checks/Check_Hostname_Inventory_linux.sh" | sudo bash
#
# NOTES:
#   Author: IT Admin
#   Version: 1.0
#   Platform: Linux (all distributions)

# ============================================================================
# CONFIGURATION
# ============================================================================
REQUIRED_PREFIX="IA"
LOG_FILE="/var/log/HostnameCheck_$(date +%Y%m%d_%H%M%S).log"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" | tee -a "$LOG_FILE" 2>/dev/null
}

get_hostname_info() {
    # Get various hostname formats
    HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
    HOSTNAME_FQDN=$(hostname -f 2>/dev/null || echo "N/A")
    HOSTNAME_FILE=$(cat /etc/hostname 2>/dev/null || echo "N/A")
}

check_prefix() {
    local hostname="$1"
    local prefix="$2"
    
    # Case-insensitive check if hostname starts with prefix
    if [[ "${hostname^^}" == "${prefix^^}"* ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log "=========================================="
log "Hostname Inventory Check"
log "=========================================="
log "Check Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Required Prefix: $REQUIRED_PREFIX"
log "Log File: $LOG_FILE"

# Get hostname information
get_hostname_info

log "Hostname (short): $HOSTNAME_SHORT"
log "Hostname (FQDN): $HOSTNAME_FQDN"
log "Hostname (/etc/hostname): $HOSTNAME_FILE"

# Get additional system info
DISTRO=$(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d'"' -f2 || echo "Unknown")
log "Distribution: $DISTRO"

echo ""
echo "=========================================="
echo "Hostname Inventory Check"
echo "=========================================="
echo "Distribution: $DISTRO"
echo ""

# Check if hostname starts with required prefix
if check_prefix "$HOSTNAME_SHORT" "$REQUIRED_PREFIX"; then
    log "Hostname Status: COMPLIANT"
    log "=========================================="
    
    echo "OK: Hostname complies with inventory naming convention"
    echo "Hostname: $HOSTNAME_SHORT"
    echo "FQDN: $HOSTNAME_FQDN"
    echo "Naming Convention: Starts with '$REQUIRED_PREFIX'"
    
    exit 0
else
    log "Hostname Status: NON-COMPLIANT" "WARNING"
    log "Expected prefix: $REQUIRED_PREFIX" "WARNING"
    log "=========================================="
    
    echo "CRITICAL: Hostname does NOT comply with inventory naming convention"
    echo "Current Hostname: $HOSTNAME_SHORT"
    echo "FQDN: $HOSTNAME_FQDN"
    echo "Required: Hostname must start with '$REQUIRED_PREFIX'"
    
    exit 2
fi
