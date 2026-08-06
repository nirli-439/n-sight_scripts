#!/usr/bin/env bash
# =============================================================================
# Remediate_Linux_Daemons.sh - Linux Daemon Remediation for N-sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Automatically diagnose and fix common Linux daemon service issues.
#     
# DESCRIPTION:
#     This remediation script addresses common Linux daemon problems including:
#     - D-Bus activated services not responding (fprintd, realmd, systemd-*)
#     - Network services issues (NetworkManager-dispatcher)
#     - Firmware update daemon (fwupd)
#     - Virtualization services (virtqemud, libvirtd)
#     - Missing packages and dependencies
#     - Service configuration issues
#     - Failed services requiring reset
#     
#     Remediation steps performed automatically:
#     1. Detect Linux distribution and package manager
#     2. Check and install missing packages
#     3. Reset failed services
#     4. Reload systemd daemon
#     5. Verify D-Bus configuration
#     6. Test service activation
#     7. Configure auto-restart for persistent services
#     8. Verify health post-remediation
#     
#     Designed for N-Sight RMM deployment - just run it, no parameters needed.
#     
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Linux_Daemons.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Linux_Daemons.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: Fedora 38+, RHEL 8+, CentOS Stream 8+
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Linux Daemon Remediation"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/daemon_remediation_$(date +%Y%m%d_%H%M%S).log"

# Package manager (detected at runtime)
PKG_MGR=""
PKG_INSTALL=""
PKG_REINSTALL=""

# Service configurations - format: "service:package:type"
# Types: dbus, socket, persistent
declare -A SERVICE_PACKAGES=(
    ["fprintd.service"]="fprintd:dbus"
    ["realmd.service"]="realmd:dbus"
    ["systemd-hostnamed.service"]="systemd:dbus"
    ["systemd-localed.service"]="systemd:dbus"
    ["systemd-timedated.service"]="systemd:dbus"
    ["NetworkManager-dispatcher.service"]="NetworkManager:dbus"
    ["NetworkManager.service"]="NetworkManager:persistent"
    ["fwupd.service"]="fwupd:dbus"
    ["virtqemud.service"]="libvirt-daemon-driver-qemu:socket"
    ["libvirtd.service"]="libvirt-daemon:socket"
    ["packagekit.service"]="PackageKit:dbus"
)

# Counters
ISSUES_FOUND=0
ISSUES_FIXED=0
ERRORS=()
REQUIRES_REBOOT=false

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

detect_package_manager() {
    log "Detecting package manager..."
    
    if [[ -f /etc/fedora-release ]]; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_REINSTALL="dnf reinstall -y"
        log "Detected: Fedora with dnf"
    elif [[ -f /etc/redhat-release ]]; then
        if command -v dnf &>/dev/null; then
            PKG_MGR="dnf"
            PKG_INSTALL="dnf install -y"
            PKG_REINSTALL="dnf reinstall -y"
        else
            PKG_MGR="yum"
            PKG_INSTALL="yum install -y"
            PKG_REINSTALL="yum reinstall -y"
        fi
        log "Detected: RHEL/CentOS with $PKG_MGR"
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_REINSTALL="apt-get install --reinstall -y"
        log "Detected: Debian/Ubuntu with apt"
    else
        log "Could not detect package manager" "ERROR"
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

# Check if package is installed
is_package_installed() {
    local package="$1"
    
    case "$PKG_MGR" in
        dnf|yum)
            rpm -q "$package" &>/dev/null
            ;;
        apt)
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
    esac
}

# Install a package
install_package() {
    local package="$1"
    
    log "Installing package: $package"
    
    if $PKG_INSTALL "$package" >> "$LOG_FILE" 2>&1; then
        log "Successfully installed: $package" "SUCCESS"
        ((ISSUES_FIXED++))
        return 0
    else
        log "Failed to install: $package" "ERROR"
        ERRORS+=("Failed to install $package")
        return 1
    fi
}

# Reinstall a package
reinstall_package() {
    local package="$1"
    
    log "Reinstalling package: $package"
    
    if $PKG_REINSTALL "$package" >> "$LOG_FILE" 2>&1; then
        log "Successfully reinstalled: $package" "SUCCESS"
        ((ISSUES_FIXED++))
        return 0
    else
        log "Failed to reinstall: $package" "WARN"
        return 1
    fi
}

# Reset failed service state
reset_failed_service() {
    local service="$1"
    
    local state
    state=$(systemctl show "$service" --property=ActiveState --value 2>/dev/null)
    
    if [[ "$state" == "failed" ]]; then
        log "Resetting failed service: $service"
        ((ISSUES_FOUND++))
        
        if systemctl reset-failed "$service" >> "$LOG_FILE" 2>&1; then
            log "Reset failed state for: $service" "SUCCESS"
            ((ISSUES_FIXED++))
            return 0
        else
            log "Could not reset: $service" "WARN"
            return 1
        fi
    fi
    
    return 0
}

# Check and fix D-Bus service file
check_dbus_service() {
    local service="$1"
    local dbus_name=""
    
    # Map service to D-Bus service file
    case "$service" in
        "systemd-hostnamed.service") dbus_name="org.freedesktop.hostname1" ;;
        "systemd-localed.service")   dbus_name="org.freedesktop.locale1" ;;
        "systemd-timedated.service") dbus_name="org.freedesktop.timedate1" ;;
        "realmd.service")            dbus_name="org.freedesktop.realmd" ;;
        "fprintd.service")           dbus_name="net.reactivated.Fprint" ;;
        "fwupd.service")             dbus_name="org.freedesktop.fwupd" ;;
        "packagekit.service")        dbus_name="org.freedesktop.PackageKit" ;;
        *)                           return 0 ;;
    esac
    
    local dbus_file="/usr/share/dbus-1/system-services/${dbus_name}.service"
    
    if [[ ! -f "$dbus_file" ]]; then
        log "D-Bus service file missing: $dbus_file" "WARN"
        ((ISSUES_FOUND++))
        return 1
    fi
    
    return 0
}

# Configure service recovery (restart on failure)
configure_service_recovery() {
    local service="$1"
    local service_type="$2"
    
    # Only configure recovery for persistent services
    if [[ "$service_type" != "persistent" ]]; then
        return 0
    fi
    
    local service_name="${service%.service}"
    local override_dir="/etc/systemd/system/${service}.d"
    local override_file="${override_dir}/restart.conf"
    
    # Check if already configured
    if [[ -f "$override_file" ]]; then
        log "Service recovery already configured for: $service"
        return 0
    fi
    
    log "Configuring auto-restart for: $service"
    
    mkdir -p "$override_dir"
    
    cat > "$override_file" << 'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
    
    if [[ -f "$override_file" ]]; then
        log "Created restart configuration for: $service" "SUCCESS"
        ((ISSUES_FIXED++))
        return 0
    else
        log "Failed to create restart config for: $service" "WARN"
        return 1
    fi
}

# Start or restart a service
start_service() {
    local service="$1"
    local service_type="$2"
    
    # For D-Bus/socket services, we just verify they can activate
    if [[ "$service_type" == "dbus" ]] || [[ "$service_type" == "socket" ]]; then
        log "Testing activation for: $service"
        
        # Try to start - may succeed or may not be needed
        systemctl start "$service" >> "$LOG_FILE" 2>&1 || true
        return 0
    fi
    
    # For persistent services, ensure they're running
    local state
    state=$(systemctl is-active "$service" 2>/dev/null)
    
    if [[ "$state" != "active" ]]; then
        log "Starting service: $service"
        ((ISSUES_FOUND++))
        
        systemctl enable "$service" >> "$LOG_FILE" 2>&1 || true
        
        if systemctl start "$service" >> "$LOG_FILE" 2>&1; then
            log "Started: $service" "SUCCESS"
            ((ISSUES_FIXED++))
            return 0
        else
            log "Failed to start: $service" "ERROR"
            ERRORS+=("Failed to start $service")
            return 1
        fi
    fi
    
    return 0
}

# Test service functionality
test_service() {
    local service="$1"
    local result=0
    
    case "$service" in
        "systemd-hostnamed.service")
            log "Testing hostnamectl..."
            if hostnamectl status >> "$LOG_FILE" 2>&1; then
                log "hostnamectl: OK" "SUCCESS"
            else
                log "hostnamectl: FAILED" "WARN"
                result=1
            fi
            ;;
        "systemd-localed.service")
            log "Testing localectl..."
            if localectl status >> "$LOG_FILE" 2>&1; then
                log "localectl: OK" "SUCCESS"
            else
                log "localectl: FAILED" "WARN"
                result=1
            fi
            ;;
        "systemd-timedated.service")
            log "Testing timedatectl..."
            if timedatectl status >> "$LOG_FILE" 2>&1; then
                log "timedatectl: OK" "SUCCESS"
            else
                log "timedatectl: FAILED" "WARN"
                result=1
            fi
            ;;
        "realmd.service")
            if command -v realm &>/dev/null; then
                log "Testing realm..."
                if realm list >> "$LOG_FILE" 2>&1; then
                    log "realm: OK" "SUCCESS"
                else
                    log "realm: No domains joined (OK for standalone)" "SUCCESS"
                fi
            fi
            ;;
        "fwupd.service")
            if command -v fwupdmgr &>/dev/null; then
                log "Testing fwupdmgr..."
                if fwupdmgr get-devices --no-unreported-check >> "$LOG_FILE" 2>&1; then
                    log "fwupdmgr: OK" "SUCCESS"
                else
                    log "fwupdmgr: No supported devices (OK)" "SUCCESS"
                fi
            fi
            ;;
        "virtqemud.service"|"libvirtd.service")
            if command -v virsh &>/dev/null; then
                log "Testing virsh..."
                if virsh -c qemu:///system list --all >> "$LOG_FILE" 2>&1; then
                    log "virsh: OK" "SUCCESS"
                else
                    log "virsh: Connection test (may need hardware support)" "WARN"
                fi
            fi
            ;;
        "NetworkManager.service")
            if command -v nmcli &>/dev/null; then
                log "Testing nmcli..."
                if nmcli general status >> "$LOG_FILE" 2>&1; then
                    log "nmcli: OK" "SUCCESS"
                else
                    log "nmcli: FAILED" "WARN"
                    result=1
                fi
            fi
            ;;
    esac
    
    return $result
}

# Remediate a single service
remediate_service() {
    local service="$1"
    local config="${SERVICE_PACKAGES[$service]}"
    local package="${config%%:*}"
    local service_type="${config##*:}"
    
    log ""
    log "--- Remediating: $service ---"
    
    # Step 1: Check if package is installed
    if ! is_package_installed "$package"; then
        log "Package not installed: $package"
        ((ISSUES_FOUND++))
        install_package "$package"
    else
        log "Package installed: $package"
    fi
    
    # Step 2: Reset failed state if needed
    reset_failed_service "$service"
    
    # Step 3: Check D-Bus configuration for D-Bus services
    if [[ "$service_type" == "dbus" ]]; then
        if ! check_dbus_service "$service"; then
            # Try reinstalling the package to restore D-Bus files
            reinstall_package "$package"
        fi
    fi
    
    # Step 4: Configure service recovery for persistent services
    configure_service_recovery "$service" "$service_type"
    
    # Step 5: Start/enable the service
    start_service "$service" "$service_type"
    
    # Step 6: Test the service
    test_service "$service"
}

# Fix socket-activated services
fix_socket_services() {
    log ""
    log "--- Checking socket-activated services ---"
    
    local socket_services=("virtqemud.socket" "libvirtd.socket" "fwupd.socket")
    
    for socket in "${socket_services[@]}"; do
        if systemctl list-unit-files "$socket" &>/dev/null; then
            local socket_state
            socket_state=$(systemctl is-active "$socket" 2>/dev/null)
            
            if [[ "$socket_state" != "active" ]] && [[ "$socket_state" != "listening" ]]; then
                log "Enabling socket: $socket"
                systemctl enable --now "$socket" >> "$LOG_FILE" 2>&1 || true
            fi
        fi
    done
}

# Reload systemd and refresh
reload_systemd() {
    log ""
    log "--- Reloading systemd daemon ---"
    
    if systemctl daemon-reload >> "$LOG_FILE" 2>&1; then
        log "Systemd daemon reloaded" "SUCCESS"
    else
        log "Failed to reload systemd daemon" "WARN"
    fi
}

# Post-remediation health check
verify_health() {
    log ""
    log "=========================================="
    log "POST-REMEDIATION VERIFICATION"
    log "=========================================="
    
    local healthy=0
    local unhealthy=0
    
    for service in "${!SERVICE_PACKAGES[@]}"; do
        local config="${SERVICE_PACKAGES[$service]}"
        local service_type="${config##*:}"
        
        local state
        state=$(systemctl show "$service" --property=ActiveState --value 2>/dev/null)
        local load
        load=$(systemctl show "$service" --property=LoadState --value 2>/dev/null)
        
        if [[ "$load" != "loaded" ]]; then
            # Not installed - skip
            continue
        fi
        
        if [[ "$state" == "failed" ]]; then
            log "[FAIL] $service is in failed state" "ERROR"
            ((unhealthy++))
        elif [[ "$state" == "active" ]]; then
            log "[PASS] $service is running" "SUCCESS"
            ((healthy++))
        elif [[ "$service_type" == "dbus" ]] || [[ "$service_type" == "socket" ]]; then
            log "[PASS] $service is inactive (normal for ${service_type}-activated)" "SUCCESS"
            ((healthy++))
        else
            log "[WARN] $service is $state" "WARN"
            ((unhealthy++))
        fi
    done
    
    echo ""
    log "Health check: $healthy healthy, $unhealthy need attention"
    
    return $unhealthy
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
log "Distro: $(get_distro_info)"
log "Kernel: $(uname -r)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log File: $LOG_FILE"
log ""

# Pre-flight checks
check_root
detect_package_manager

# =============================================================================
# PHASE 1: Initial Setup
# =============================================================================
log ""
log "============================================"
log "PHASE 1: Initial Setup"
log "============================================"

reload_systemd

# =============================================================================
# PHASE 2: Remediate Each Service
# =============================================================================
log ""
log "============================================"
log "PHASE 2: Service Remediation"
log "============================================"

for service in "${!SERVICE_PACKAGES[@]}"; do
    remediate_service "$service"
done

# =============================================================================
# PHASE 3: Fix Socket Services
# =============================================================================
log ""
log "============================================"
log "PHASE 3: Socket Services"
log "============================================"

fix_socket_services

# =============================================================================
# PHASE 4: Final Reload and Verification
# =============================================================================
log ""
log "============================================"
log "PHASE 4: Final Verification"
log "============================================"

reload_systemd

# Wait for services to settle
sleep 3

verify_health
HEALTH_RESULT=$?

# =============================================================================
# SUMMARY
# =============================================================================
log ""
log "=========================================="
log "REMEDIATION SUMMARY"
log "=========================================="

echo ""
echo "=========================================="
echo "REMEDIATION SUMMARY"
echo "=========================================="
echo ""
echo "Issues Found: $ISSUES_FOUND"
echo "Issues Fixed: $ISSUES_FIXED"
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "Errors encountered:" "WARN"
    echo "Errors encountered:"
    for err in "${ERRORS[@]}"; do
        log "  - $err" "WARN"
        echo "  - $err"
    done
    echo ""
fi

if [[ $REQUIRES_REBOOT == true ]]; then
    log "A system reboot is recommended" "WARN"
    echo "NOTE: A system reboot is recommended to complete repairs"
    echo ""
fi

if [[ $HEALTH_RESULT -eq 0 ]] && [[ ${#ERRORS[@]} -eq 0 ]]; then
    log "Overall Status: HEALTHY" "SUCCESS"
    echo -e "\033[32mOverall Status: HEALTHY\033[0m"
    echo ""
    echo "All services are properly configured."
    echo ""
    echo "NOTE: D-Bus and socket-activated services showing 'inactive'"
    echo "is NORMAL - they activate on demand when needed."
    echo ""
    exit 0
elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "Overall Status: ISSUES REMAIN" "WARN"
    echo -e "\033[33mOverall Status: ISSUES REMAIN\033[0m"
    echo ""
    echo "POST-REMEDIATION STEPS (if issues persist):"
    echo "=========================================="
    echo "1. Check journalctl -xe for detailed errors"
    echo "2. Verify hardware support (for fprintd, virtqemud)"
    echo "3. Check SELinux: sestatus and audit.log"
    echo "4. Reinstall problematic packages manually"
    echo "5. Consider running: dnf distro-sync"
    echo ""
    exit 1
else
    log "Overall Status: COMPLETED WITH WARNINGS" "WARN"
    echo -e "\033[33mOverall Status: COMPLETED WITH WARNINGS\033[0m"
    echo ""
    exit 1
fi
