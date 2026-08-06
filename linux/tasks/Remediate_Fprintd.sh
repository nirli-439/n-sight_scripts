#!/usr/bin/env bash
# =============================================================================
# Remediate_Fprintd.sh - Fingerprint Daemon Fix for Fedora Workstation
# =============================================================================
#
# SYNOPSIS:
#     Fix fprintd (fingerprint daemon) service issues on Fedora.
#     
# DESCRIPTION:
#     fprintd is a D-Bus activated service for fingerprint reader support.
#     It's NORMAL for this service to show "inactive" - it only starts when
#     a fingerprint reader is accessed.
#     
#     This script:
#     1. Installs fprintd if missing
#     2. Resets failed state if crashed
#     3. Verifies D-Bus activation works
#     4. Tests hardware detection (if reader present)
#     
#     For systems WITHOUT fingerprint readers, this service being
#     "inactive" is completely normal and expected.
#     
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Fprintd.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Fprintd.sh" | sudo bash
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
readonly SCRIPT_NAME="Fprintd Remediation"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/fprintd_remediation_$(date +%Y%m%d_%H%M%S).log"
readonly SERVICE_NAME="fprintd.service"
readonly PACKAGE_NAME="fprintd"

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

# Check for fingerprint hardware
check_fingerprint_hardware() {
    log "Checking for fingerprint reader hardware..."
    
    # Check using lsusb for common fingerprint readers
    if command -v lsusb &>/dev/null; then
        local fp_devices
        fp_devices=$(lsusb 2>/dev/null | grep -iE "(fingerprint|validity|auth|synaptics|goodix|elan|fprint)" || true)
        
        if [[ -n "$fp_devices" ]]; then
            log "Found fingerprint hardware:"
            log "$fp_devices"
            return 0
        fi
    fi
    
    # Check sysfs for fingerprint devices
    if ls /sys/class/fingerprint/* &>/dev/null 2>&1; then
        log "Found fingerprint device in sysfs"
        return 0
    fi
    
    log "No fingerprint hardware detected (this is OK for most systems)"
    return 1
}

# Install package if missing
install_package() {
    if ! rpm -q "$PACKAGE_NAME" &>/dev/null; then
        log "Package $PACKAGE_NAME not installed. Installing..."
        
        if dnf install -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1; then
            log "Successfully installed $PACKAGE_NAME" "SUCCESS"
            return 0
        else
            log "Failed to install $PACKAGE_NAME" "ERROR"
            return 1
        fi
    else
        log "Package $PACKAGE_NAME is already installed"
        return 0
    fi
}

# Reset failed service state
reset_service() {
    local state
    state=$(systemctl show "$SERVICE_NAME" --property=ActiveState --value 2>/dev/null)
    
    if [[ "$state" == "failed" ]]; then
        log "Service is in failed state. Resetting..."
        
        if systemctl reset-failed "$SERVICE_NAME" >> "$LOG_FILE" 2>&1; then
            log "Reset failed state" "SUCCESS"
            return 0
        else
            log "Could not reset failed state" "WARN"
            return 1
        fi
    else
        log "Service state: $state"
    fi
    
    return 0
}

# Reinstall D-Bus configuration
fix_dbus_config() {
    local dbus_file="/usr/share/dbus-1/system-services/net.reactivated.Fprint.service"
    
    if [[ ! -f "$dbus_file" ]]; then
        log "D-Bus service file missing. Reinstalling package..."
        
        if dnf reinstall -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1; then
            log "Reinstalled $PACKAGE_NAME" "SUCCESS"
            return 0
        else
            log "Failed to reinstall $PACKAGE_NAME" "WARN"
            return 1
        fi
    else
        log "D-Bus configuration file exists"
    fi
    
    return 0
}

# Test D-Bus activation
test_dbus_activation() {
    log "Testing D-Bus activation..."
    
    # Try to start the service
    if systemctl start "$SERVICE_NAME" >> "$LOG_FILE" 2>&1; then
        log "Service started successfully" "SUCCESS"
        
        # Check if we have hardware
        if check_fingerprint_hardware; then
            # Test fprintd-list if hardware present
            if command -v fprintd-list &>/dev/null; then
                log "Testing fprintd-list..."
                if fprintd-list "$USER" >> "$LOG_FILE" 2>&1 || true; then
                    log "fprintd-list executed (check for enrolled prints)" "SUCCESS"
                fi
            fi
        fi
        
        return 0
    else
        log "Service failed to start - may need fingerprint hardware" "WARN"
        return 1
    fi
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

log "Starting fprintd remediation..."
log ""

# Step 1: Install package
log "STEP 1: Checking package installation..."
install_package

# Step 2: Reload systemd
log ""
log "STEP 2: Reloading systemd daemon..."
systemctl daemon-reload >> "$LOG_FILE" 2>&1
log "Systemd reloaded" "SUCCESS"

# Step 3: Reset service if failed
log ""
log "STEP 3: Checking service state..."
reset_service

# Step 4: Fix D-Bus configuration
log ""
log "STEP 4: Checking D-Bus configuration..."
fix_dbus_config

# Step 5: Test activation
log ""
log "STEP 5: Testing service activation..."
test_dbus_activation
TEST_RESULT=$?

# Summary
log ""
log "=========================================="
log "SUMMARY"
log "=========================================="

HAS_HARDWARE=false
if check_fingerprint_hardware; then
    HAS_HARDWARE=true
fi

if [[ $TEST_RESULT -eq 0 ]]; then
    echo ""
    echo -e "\033[32mSUCCESS: fprintd service is working\033[0m"
    echo ""
    if [[ $HAS_HARDWARE == true ]]; then
        echo "Fingerprint hardware detected."
        echo "You can enroll fingerprints with: fprintd-enroll"
    else
        echo "NOTE: No fingerprint hardware detected."
        echo "Service is inactive (normal) - will activate if reader is connected."
    fi
    echo ""
    log "Overall Status: SUCCESS" "SUCCESS"
    exit 0
else
    echo ""
    if [[ $HAS_HARDWARE == true ]]; then
        echo -e "\033[33mWARNING: fprintd service has issues\033[0m"
        echo ""
        echo "Troubleshooting steps:"
        echo "1. Check journalctl -u fprintd for errors"
        echo "2. Verify hardware with: lsusb | grep -i finger"
        echo "3. Check SELinux: ausearch -m avc -ts recent | grep fprintd"
        echo "4. Try: dnf reinstall fprintd fprintd-pam"
    else
        echo -e "\033[32mOK: No fingerprint hardware - service inactive is normal\033[0m"
        echo ""
        echo "fprintd is a D-Bus activated service."
        echo "Without fingerprint hardware, 'inactive' status is expected."
        exit 0
    fi
    echo ""
    log "Overall Status: WARNING" "WARN"
    exit 1
fi
