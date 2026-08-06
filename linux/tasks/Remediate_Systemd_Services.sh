#!/usr/bin/env bash
# =============================================================================
# Remediate_Systemd_Services.sh - Fix systemd-hostnamed/localed/timedated
# =============================================================================
#
# SYNOPSIS:
#     Fix systemd core services (hostnamed, localed, timedated) on Fedora.
#     
# DESCRIPTION:
#     These are D-Bus activated services that provide:
#     - systemd-hostnamed: hostname configuration (hostnamectl)
#     - systemd-localed: locale/keyboard configuration (localectl)
#     - systemd-timedated: time/date configuration (timedatectl)
#     
#     These services are SUPPOSED to show "inactive" most of the time.
#     They only activate when their respective tools are used.
#     
#     This script:
#     1. Verifies systemd package is complete
#     2. Resets failed states
#     3. Tests all three services by running their CLI tools
#     4. Fixes D-Bus configuration if needed
#     5. Ensures NTP synchronization is configured
#     
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Systemd_Services.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Systemd_Services.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, Fedora Workstation 42
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Systemd Services Remediation"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/systemd_services_remediation_$(date +%Y%m%d_%H%M%S).log"

# Services to fix
declare -A SERVICES=(
    ["systemd-hostnamed.service"]="org.freedesktop.hostname1:hostnamectl"
    ["systemd-localed.service"]="org.freedesktop.locale1:localectl"
    ["systemd-timedated.service"]="org.freedesktop.timedate1:timedatectl"
)

# Results tracking
declare -A RESULTS

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    
    case "$level" in
        ERROR)   echo -e "\033[31m${message}\033[0m" ;;
        WARN)    echo -e "\033[33m${message}\033[0m" ;;
        SUCCESS) echo -e "\033[32m${message}\033[0m" ;;
        *)       echo "$message" ;;
    esac
    
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        exit 2
    fi
}

get_distro_info() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${NAME:-Unknown} ${VERSION_ID:-}"
    else
        echo "Unknown"
    fi
}

# Verify systemd package integrity
verify_systemd_package() {
    log "Verifying systemd package integrity..."
    
    if rpm -V systemd >> "$LOG_FILE" 2>&1; then
        log "systemd package integrity: OK" "SUCCESS"
        return 0
    else
        log "systemd package may have modified files" "WARN"
        log "Attempting to reinstall systemd..."
        
        if dnf reinstall -y systemd >> "$LOG_FILE" 2>&1; then
            log "Reinstalled systemd" "SUCCESS"
            return 0
        else
            log "Could not reinstall systemd" "WARN"
            return 1
        fi
    fi
}

# Reset failed service
reset_service() {
    local service="$1"
    
    local state
    state=$(systemctl show "$service" --property=ActiveState --value 2>/dev/null)
    
    if [[ "$state" == "failed" ]]; then
        log "Resetting failed service: $service"
        systemctl reset-failed "$service" >> "$LOG_FILE" 2>&1
        return 0
    fi
    
    return 0
}

# Check D-Bus service file
check_dbus_file() {
    local service="$1"
    local config="${SERVICES[$service]}"
    local dbus_name="${config%%:*}"
    local dbus_file="/usr/share/dbus-1/system-services/${dbus_name}.service"
    
    if [[ ! -f "$dbus_file" ]]; then
        log "D-Bus file missing: $dbus_file" "WARN"
        return 1
    fi
    
    log "D-Bus file exists: $dbus_file"
    return 0
}

# Test service via CLI tool
test_service() {
    local service="$1"
    local config="${SERVICES[$service]}"
    local cli_tool="${config##*:}"
    
    log "Testing: $cli_tool status"
    
    local output
    if output=$($cli_tool status 2>&1); then
        log "$cli_tool: OK" "SUCCESS"
        RESULTS["$service"]="PASS"
        return 0
    else
        log "$cli_tool failed: $output" "WARN"
        RESULTS["$service"]="FAIL"
        return 1
    fi
}

# Configure NTP synchronization
configure_ntp() {
    log ""
    log "Checking NTP synchronization..."
    
    # Check current NTP status
    local ntp_status
    ntp_status=$(timedatectl show --property=NTP --value 2>/dev/null)
    
    if [[ "$ntp_status" != "yes" ]]; then
        log "NTP is disabled. Enabling..."
        
        if timedatectl set-ntp true >> "$LOG_FILE" 2>&1; then
            log "NTP enabled" "SUCCESS"
        else
            log "Could not enable NTP" "WARN"
        fi
    else
        log "NTP is already enabled" "SUCCESS"
    fi
    
    # Check if chronyd is running (Fedora default)
    if systemctl is-active chronyd &>/dev/null; then
        log "chronyd is running (NTP sync active)" "SUCCESS"
    elif systemctl is-active systemd-timesyncd &>/dev/null; then
        log "systemd-timesyncd is running (NTP sync active)" "SUCCESS"
    else
        log "No NTP service running - enabling chronyd..."
        systemctl enable --now chronyd >> "$LOG_FILE" 2>&1 || true
    fi
}

# Fix hostname if needed
fix_hostname() {
    log ""
    log "Checking hostname configuration..."
    
    local hostname
    hostname=$(hostnamectl hostname 2>/dev/null || hostname)
    
    if [[ -z "$hostname" ]] || [[ "$hostname" == "localhost" ]] || [[ "$hostname" == "localhost.localdomain" ]]; then
        log "Hostname is generic: $hostname" "WARN"
        echo "Consider setting a proper hostname with: hostnamectl set-hostname YOUR-HOSTNAME"
    else
        log "Hostname: $hostname" "SUCCESS"
    fi
}

# Remediate single service
remediate_service() {
    local service="$1"
    
    log ""
    log "--- Remediating: $service ---"
    
    # Reset if failed
    reset_service "$service"
    
    # Check D-Bus file
    if ! check_dbus_file "$service"; then
        log "D-Bus configuration issue - reinstalling systemd..."
        dnf reinstall -y systemd >> "$LOG_FILE" 2>&1 || true
    fi
    
    # Test via CLI
    test_service "$service"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "Distro: $(get_distro_info)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log ""

check_root

log "Starting systemd services remediation..."
log ""

# Step 1: Verify systemd package
log "STEP 1: Verifying systemd package..."
verify_systemd_package

# Step 2: Reload systemd
log ""
log "STEP 2: Reloading systemd daemon..."
systemctl daemon-reload >> "$LOG_FILE" 2>&1
log "Systemd reloaded" "SUCCESS"

# Step 3: Remediate each service
log ""
log "STEP 3: Remediating services..."

for service in "${!SERVICES[@]}"; do
    remediate_service "$service"
done

# Step 4: Configure NTP
log ""
log "STEP 4: Configuring NTP..."
configure_ntp

# Step 5: Check hostname
log ""
log "STEP 5: Checking hostname..."
fix_hostname

# Summary
log ""
log "=========================================="
log "SUMMARY"
log "=========================================="

PASS_COUNT=0
FAIL_COUNT=0

echo ""
echo "=========================================="
echo "SERVICE TEST RESULTS"
echo "=========================================="
echo ""

for service in "${!RESULTS[@]}"; do
    local result="${RESULTS[$service]}"
    local config="${SERVICES[$service]}"
    local cli_tool="${config##*:}"
    
    if [[ "$result" == "PASS" ]]; then
        echo -e "[\033[32mPASS\033[0m] $service ($cli_tool works)"
        ((PASS_COUNT++))
    else
        echo -e "[\033[31mFAIL\033[0m] $service ($cli_tool failed)"
        ((FAIL_COUNT++))
    fi
done

echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "\033[32mSUCCESS: All systemd services are working\033[0m"
    echo ""
    echo "NOTE: These services showing 'inactive' in systemctl status"
    echo "is NORMAL - they are D-Bus activated and only run when needed."
    echo ""
    echo "Quick status:"
    echo "  hostnamectl  - $(hostnamectl hostname 2>/dev/null || echo 'N/A')"
    echo "  localectl    - $(localectl status 2>/dev/null | head -1 || echo 'N/A')"
    echo "  timedatectl  - $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'N/A')"
    echo ""
    log "Overall Status: SUCCESS" "SUCCESS"
    exit 0
else
    echo -e "\033[33mWARNING: $FAIL_COUNT service(s) have issues\033[0m"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check journalctl -u SERVICE_NAME for errors"
    echo "2. Verify D-Bus is running: systemctl status dbus"
    echo "3. Check SELinux: ausearch -m avc -ts recent"
    echo "4. Try: dnf reinstall systemd"
    echo "5. Consider reboot if issues persist"
    echo ""
    log "Overall Status: WARNING" "WARN"
    exit 1
fi
