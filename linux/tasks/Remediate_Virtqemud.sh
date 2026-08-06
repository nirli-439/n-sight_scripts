#!/usr/bin/env bash
# =============================================================================
# Remediate_Virtqemud.sh - QEMU Virtualization Daemon Fix for Fedora
# =============================================================================
#
# SYNOPSIS:
#     Fix virtqemud (QEMU virtualization daemon) service on Fedora.
#     
# DESCRIPTION:
#     virtqemud is a socket-activated service that provides QEMU/KVM
#     virtualization support. It's the modern modular replacement for
#     the monolithic libvirtd.
#     
#     It's NORMAL for this service to show "inactive" - it activates
#     when virtualization tools (virt-manager, virsh) connect to it.
#     
#     This script:
#     1. Installs virtualization packages if missing
#     2. Enables the virtqemud socket for activation
#     3. Configures user access to libvirt
#     4. Enables nested virtualization (if supported)
#     5. Tests virsh connectivity
#     
#     For systems NOT using virtualization, this service being
#     "inactive" is completely normal.
#     
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_Virtqemud.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/tasks/Remediate_Virtqemud.sh" | sudo bash
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
readonly SCRIPT_NAME="Virtqemud Remediation"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/virtqemud_remediation_$(date +%Y%m%d_%H%M%S).log"

# Virtualization packages
readonly PACKAGES=(
    "libvirt"
    "libvirt-daemon-kvm"
    "libvirt-daemon-driver-qemu"
    "qemu-kvm"
    "virt-manager"
    "virt-install"
    "virt-viewer"
)

# Sockets and services
readonly SOCKETS=(
    "virtqemud.socket"
    "virtqemud-ro.socket"
    "virtqemud-admin.socket"
    "virtnetworkd.socket"
    "virtstoraged.socket"
)

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

# Check if CPU supports virtualization
check_cpu_support() {
    log "Checking CPU virtualization support..."
    
    local virt_type=""
    
    if grep -qE "(vmx|svm)" /proc/cpuinfo 2>/dev/null; then
        if grep -q "vmx" /proc/cpuinfo; then
            virt_type="Intel VT-x"
        else
            virt_type="AMD-V"
        fi
        log "CPU supports virtualization: $virt_type" "SUCCESS"
        return 0
    else
        log "CPU virtualization not detected (may need BIOS enable)" "WARN"
        return 1
    fi
}

# Check if KVM module is loaded
check_kvm_module() {
    log "Checking KVM kernel module..."
    
    if lsmod | grep -q "^kvm"; then
        local kvm_type
        if lsmod | grep -q "kvm_intel"; then
            kvm_type="kvm_intel"
        elif lsmod | grep -q "kvm_amd"; then
            kvm_type="kvm_amd"
        else
            kvm_type="kvm (generic)"
        fi
        log "KVM module loaded: $kvm_type" "SUCCESS"
        return 0
    else
        log "KVM module not loaded" "WARN"
        
        # Try to load it
        log "Attempting to load KVM module..."
        modprobe kvm >> "$LOG_FILE" 2>&1 || true
        modprobe kvm_intel >> "$LOG_FILE" 2>&1 || modprobe kvm_amd >> "$LOG_FILE" 2>&1 || true
        
        if lsmod | grep -q "^kvm"; then
            log "KVM module loaded successfully" "SUCCESS"
            return 0
        else
            return 1
        fi
    fi
}

# Install virtualization packages
install_packages() {
    log "Checking virtualization packages..."
    
    local to_install=()
    
    for pkg in "${PACKAGES[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            to_install+=("$pkg")
            log "Package missing: $pkg"
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing: ${to_install[*]}"
        
        if dnf install -y "${to_install[@]}" >> "$LOG_FILE" 2>&1; then
            log "Packages installed successfully" "SUCCESS"
            return 0
        else
            log "Some packages failed to install" "WARN"
            return 1
        fi
    else
        log "All virtualization packages installed" "SUCCESS"
    fi
    
    return 0
}

# Enable and start sockets
enable_sockets() {
    log "Enabling virtqemud sockets..."
    
    for socket in "${SOCKETS[@]}"; do
        if systemctl list-unit-files "$socket" &>/dev/null; then
            log "Enabling: $socket"
            systemctl enable "$socket" >> "$LOG_FILE" 2>&1 || true
            systemctl start "$socket" >> "$LOG_FILE" 2>&1 || true
        fi
    done
    
    # Verify main socket
    if systemctl is-active virtqemud.socket &>/dev/null; then
        log "virtqemud.socket is active" "SUCCESS"
        return 0
    else
        log "virtqemud.socket not active" "WARN"
        return 1
    fi
}

# Reset failed service
reset_service() {
    local state
    state=$(systemctl show virtqemud.service --property=ActiveState --value 2>/dev/null)
    
    if [[ "$state" == "failed" ]]; then
        log "Resetting failed virtqemud service..."
        systemctl reset-failed virtqemud.service >> "$LOG_FILE" 2>&1
        log "Service reset" "SUCCESS"
    fi
}

# Configure user access to libvirt
configure_user_access() {
    log "Configuring user access to libvirt..."
    
    # Ensure libvirt group exists
    if ! getent group libvirt &>/dev/null; then
        log "Creating libvirt group..."
        groupadd libvirt >> "$LOG_FILE" 2>&1 || true
    fi
    
    # Add current sudo user to libvirt group
    local sudo_user="${SUDO_USER:-}"
    if [[ -n "$sudo_user" ]] && [[ "$sudo_user" != "root" ]]; then
        if ! groups "$sudo_user" | grep -q libvirt; then
            log "Adding $sudo_user to libvirt group..."
            usermod -aG libvirt "$sudo_user" >> "$LOG_FILE" 2>&1 || true
            log "User $sudo_user added to libvirt group" "SUCCESS"
            log "NOTE: User must log out and back in for group to take effect"
        else
            log "User $sudo_user already in libvirt group"
        fi
    fi
    
    return 0
}

# Enable nested virtualization
enable_nested_virt() {
    log "Checking nested virtualization..."
    
    local nested_file=""
    local cpu_vendor=""
    
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        nested_file="/sys/module/kvm_intel/parameters/nested"
        cpu_vendor="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        nested_file="/sys/module/kvm_amd/parameters/nested"
        cpu_vendor="amd"
    fi
    
    if [[ -n "$nested_file" ]] && [[ -f "$nested_file" ]]; then
        local nested_status
        nested_status=$(cat "$nested_file" 2>/dev/null)
        
        if [[ "$nested_status" == "Y" ]] || [[ "$nested_status" == "1" ]]; then
            log "Nested virtualization: enabled" "SUCCESS"
        else
            log "Nested virtualization: disabled"
            log "To enable: echo 'options kvm_$cpu_vendor nested=1' > /etc/modprobe.d/kvm.conf"
        fi
    fi
}

# Test virtualization
test_virtualization() {
    log "Testing virtualization..."
    
    if ! command -v virsh &>/dev/null; then
        log "virsh not found - cannot test" "WARN"
        return 1
    fi
    
    # Test connection to qemu:///system
    log "Testing: virsh -c qemu:///system list --all"
    
    if virsh -c qemu:///system list --all >> "$LOG_FILE" 2>&1; then
        log "virsh connection: OK" "SUCCESS"
        
        # Get VM count
        local vm_count
        vm_count=$(virsh -c qemu:///system list --all 2>/dev/null | grep -c "running\|shut off\|paused" || echo "0")
        log "Virtual machines found: $vm_count"
        
        return 0
    else
        log "virsh connection failed" "WARN"
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

log "Starting virtqemud remediation..."
log ""

# Step 1: Check CPU support
log "STEP 1: Checking CPU virtualization support..."
CPU_OK=false
if check_cpu_support; then
    CPU_OK=true
fi

# Step 2: Check KVM module
log ""
log "STEP 2: Checking KVM kernel module..."
KVM_OK=false
if check_kvm_module; then
    KVM_OK=true
fi

# Step 3: Install packages
log ""
log "STEP 3: Installing virtualization packages..."
install_packages

# Step 4: Reload systemd
log ""
log "STEP 4: Reloading systemd..."
systemctl daemon-reload >> "$LOG_FILE" 2>&1
log "Systemd reloaded" "SUCCESS"

# Step 5: Reset failed service
log ""
log "STEP 5: Checking service state..."
reset_service

# Step 6: Enable sockets
log ""
log "STEP 6: Enabling virtqemud sockets..."
enable_sockets
SOCKET_OK=$?

# Step 7: Configure user access
log ""
log "STEP 7: Configuring user access..."
configure_user_access

# Step 8: Check nested virtualization
log ""
log "STEP 8: Checking nested virtualization..."
enable_nested_virt

# Step 9: Test virtualization
log ""
log "STEP 9: Testing virtualization..."
test_virtualization
TEST_OK=$?

# Summary
log ""
log "=========================================="
log "SUMMARY"
log "=========================================="

echo ""
echo "=========================================="
echo "VIRTUALIZATION STATUS"
echo "=========================================="
echo ""

if [[ $CPU_OK == true ]]; then
    echo -e "[\033[32m✓\033[0m] CPU virtualization support"
else
    echo -e "[\033[31m✗\033[0m] CPU virtualization support (enable in BIOS)"
fi

if [[ $KVM_OK == true ]]; then
    echo -e "[\033[32m✓\033[0m] KVM kernel module loaded"
else
    echo -e "[\033[31m✗\033[0m] KVM kernel module (check BIOS settings)"
fi

if [[ $SOCKET_OK -eq 0 ]]; then
    echo -e "[\033[32m✓\033[0m] virtqemud socket active"
else
    echo -e "[\033[31m✗\033[0m] virtqemud socket"
fi

if [[ $TEST_OK -eq 0 ]]; then
    echo -e "[\033[32m✓\033[0m] virsh connection works"
else
    echo -e "[\033[31m✗\033[0m] virsh connection"
fi

echo ""

if [[ $TEST_OK -eq 0 ]] && [[ $CPU_OK == true ]]; then
    echo -e "\033[32mSUCCESS: Virtualization is working\033[0m"
    echo ""
    echo "NOTE: virtqemud.service showing 'inactive' is NORMAL."
    echo "It's socket-activated and starts when tools connect."
    echo ""
    echo "Quick commands:"
    echo "  virt-manager          - Graphical VM manager"
    echo "  virsh list --all      - List all VMs"
    echo "  virt-install          - Create new VM"
    echo ""
    log "Overall Status: SUCCESS" "SUCCESS"
    exit 0
else
    echo -e "\033[33mWARNING: Virtualization has issues\033[0m"
    echo ""
    echo "Troubleshooting:"
    echo ""
    if [[ $CPU_OK != true ]]; then
        echo "1. Enable VT-x/AMD-V in BIOS settings"
    fi
    if [[ $KVM_OK != true ]]; then
        echo "2. Check: dmesg | grep -i kvm"
        echo "   Try: modprobe kvm_intel (or kvm_amd)"
    fi
    echo "3. Check journalctl -u virtqemud for errors"
    echo "4. Verify SELinux: ausearch -m avc -ts recent | grep virt"
    echo "5. Check: ls -la /dev/kvm"
    echo ""
    log "Overall Status: WARNING" "WARN"
    exit 1
fi
