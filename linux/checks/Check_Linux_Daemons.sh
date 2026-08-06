#!/usr/bin/env bash
# =============================================================================
# Check_Linux_Daemons.sh - Linux Daemon Health Check for N-sight RMM
# =============================================================================
#
# SYNOPSIS:
#     Check health status of common Linux system daemons.
#     
# DESCRIPTION:
#     This monitoring script verifies the health of Linux system services:
#     - D-Bus activated services (fprintd, realmd, systemd-*)
#     - Network services (NetworkManager-dispatcher)
#     - Firmware services (fwupd)
#     - Virtualization services (virtqemud, libvirtd)
#     - Package management (packagekit)
#     
#     IMPORTANT: Many of these services are "D-Bus activated" or "socket activated"
#     which means they are SUPPOSED to show "inactive" when not in use. This is
#     normal behavior, not a failure. The script accounts for this.
#     
#     Designed for N-Sight RMM deployment on Fedora/RHEL/CentOS systems.
#     
#     Exit Codes:
#     - 0 = PASS (All services healthy or expected inactive)
#     - 1 = WARNING (Some services need attention)
#     - 2 = CRITICAL (Services failed or missing)
#     
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Linux_Daemons.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/linux/checks/Check_Linux_Daemons.sh" | sudo bash
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
readonly SCRIPT_NAME="Linux Daemon Health Check"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/daemon_check_$(date +%Y%m%d_%H%M%S).log"

# Services to check - format: "service_name:type:required"
# Types: dbus (D-Bus activated), socket (socket activated), persistent (should always run)
# Required: yes (must be installed), no (optional)
declare -A SERVICE_CONFIG=(
    ["fprintd.service"]="dbus:no"
    ["realmd.service"]="dbus:no"
    ["systemd-hostnamed.service"]="dbus:yes"
    ["systemd-localed.service"]="dbus:yes"
    ["systemd-timedated.service"]="dbus:yes"
    ["NetworkManager-dispatcher.service"]="dbus:no"
    ["NetworkManager.service"]="persistent:yes"
    ["fwupd.service"]="dbus:no"
    ["virtqemud.service"]="socket:no"
    ["libvirtd.service"]="socket:no"
    ["packagekit.service"]="dbus:no"
)

# Counters
CRITICAL_COUNT=0
WARNING_COUNT=0
PASS_COUNT=0

# Results storage
declare -A RESULTS

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    
    # Color output for terminal
    case "$level" in
        ERROR)   echo -e "\033[31m${message}\033[0m" ;;
        WARN)    echo -e "\033[33m${message}\033[0m" ;;
        SUCCESS) echo -e "\033[32m${message}\033[0m" ;;
        *)       echo "$message" ;;
    esac
    
    # Write to log file
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        exit 2
    fi
}

check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        log "systemctl not found - this script requires systemd" "ERROR"
        exit 2
    fi
}

get_distro_info() {
    local distro="Unknown"
    local version="Unknown"
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        distro="${NAME:-Unknown}"
        version="${VERSION_ID:-Unknown}"
    elif [[ -f /etc/fedora-release ]]; then
        distro="Fedora"
        version=$(cat /etc/fedora-release | grep -oP '\d+')
    elif [[ -f /etc/redhat-release ]]; then
        distro="RHEL/CentOS"
        version=$(cat /etc/redhat-release | grep -oP '\d+' | head -1)
    fi
    
    echo "$distro $version"
}

# Get service status details
get_service_status() {
    local service="$1"
    local result=""
    
    # Check if unit file exists
    if ! systemctl list-unit-files "$service" &>/dev/null; then
        echo "not_installed"
        return
    fi
    
    local unit_file_state
    unit_file_state=$(systemctl list-unit-files "$service" 2>/dev/null | grep "$service" | awk '{print $2}')
    
    if [[ -z "$unit_file_state" ]]; then
        echo "not_installed"
        return
    fi
    
    # Get active state
    local active_state
    active_state=$(systemctl show "$service" --property=ActiveState --value 2>/dev/null)
    
    # Get load state
    local load_state
    load_state=$(systemctl show "$service" --property=LoadState --value 2>/dev/null)
    
    # Get sub state (more detail)
    local sub_state
    sub_state=$(systemctl show "$service" --property=SubState --value 2>/dev/null)
    
    echo "${active_state}:${load_state}:${sub_state}:${unit_file_state}"
}

# Check if service can activate (for D-Bus/socket services)
test_service_activation() {
    local service="$1"
    local service_type="$2"
    
    case "$service" in
        "systemd-hostnamed.service")
            # Test by running hostnamectl
            if hostnamectl status &>/dev/null; then
                return 0
            fi
            ;;
        "systemd-localed.service")
            # Test by running localectl
            if localectl status &>/dev/null; then
                return 0
            fi
            ;;
        "systemd-timedated.service")
            # Test by running timedatectl
            if timedatectl status &>/dev/null; then
                return 0
            fi
            ;;
        "realmd.service")
            # Test by running realm list
            if command -v realm &>/dev/null && realm list &>/dev/null; then
                return 0
            fi
            ;;
        "fprintd.service")
            # fprintd requires hardware - just check if it can be started
            if systemctl start "$service" &>/dev/null; then
                return 0
            fi
            ;;
        "fwupd.service")
            # Test by running fwupdmgr
            if command -v fwupdmgr &>/dev/null && fwupdmgr get-devices &>/dev/null; then
                return 0
            fi
            ;;
        *)
            # Generic test - try to start the service briefly
            if systemctl start "$service" &>/dev/null; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Check a single service
check_service() {
    local service="$1"
    local config="${SERVICE_CONFIG[$service]}"
    local service_type="${config%%:*}"
    local required="${config##*:}"
    
    local status
    status=$(get_service_status "$service")
    
    local active_state="${status%%:*}"
    local remaining="${status#*:}"
    local load_state="${remaining%%:*}"
    remaining="${remaining#*:}"
    local sub_state="${remaining%%:*}"
    local unit_file_state="${remaining##*:}"
    
    local result_status="PASS"
    local result_message=""
    local result_details=""
    
    # Service not installed
    if [[ "$status" == "not_installed" ]]; then
        if [[ "$required" == "yes" ]]; then
            result_status="CRITICAL"
            result_message="Required service not installed"
            ((CRITICAL_COUNT++))
        else
            result_status="PASS"
            result_message="Optional service not installed (OK)"
            ((PASS_COUNT++))
        fi
        
        RESULTS["$service"]="${result_status}|${result_message}|Not installed|${service_type}"
        return
    fi
    
    result_details="Active: $active_state, Load: $load_state, Sub: $sub_state"
    
    # Check based on service type
    case "$service_type" in
        "dbus"|"socket")
            # D-Bus and socket activated services can be inactive - that's OK
            if [[ "$active_state" == "failed" ]]; then
                result_status="CRITICAL"
                result_message="Service is in failed state"
                ((CRITICAL_COUNT++))
            elif [[ "$active_state" == "active" ]] || [[ "$active_state" == "inactive" ]]; then
                # Test if it can activate
                if test_service_activation "$service" "$service_type"; then
                    result_status="PASS"
                    if [[ "$active_state" == "inactive" ]]; then
                        result_message="Inactive (normal for ${service_type}-activated service)"
                    else
                        result_message="Service is running"
                    fi
                    ((PASS_COUNT++))
                else
                    if [[ "$required" == "yes" ]]; then
                        result_status="WARNING"
                        result_message="Cannot activate (may need attention)"
                        ((WARNING_COUNT++))
                    else
                        result_status="PASS"
                        result_message="Inactive (optional service)"
                        ((PASS_COUNT++))
                    fi
                fi
            else
                result_status="WARNING"
                result_message="Unexpected state: $active_state"
                ((WARNING_COUNT++))
            fi
            ;;
            
        "persistent")
            # Persistent services should always be running
            if [[ "$active_state" == "active" ]]; then
                result_status="PASS"
                result_message="Service is running"
                ((PASS_COUNT++))
            elif [[ "$active_state" == "failed" ]]; then
                result_status="CRITICAL"
                result_message="Service has failed"
                ((CRITICAL_COUNT++))
            else
                if [[ "$required" == "yes" ]]; then
                    result_status="CRITICAL"
                    result_message="Required service is not running"
                    ((CRITICAL_COUNT++))
                else
                    result_status="WARNING"
                    result_message="Service is not running"
                    ((WARNING_COUNT++))
                fi
            fi
            ;;
    esac
    
    RESULTS["$service"]="${result_status}|${result_message}|${result_details}|${service_type}"
}

# Check for recent crash events
check_crash_events() {
    log "Checking for recent service failures..."
    
    local failures
    failures=$(journalctl --since "7 days ago" -p err -u "*.service" --no-pager 2>/dev/null | \
        grep -E "(fprintd|realmd|systemd-hostnamed|systemd-localed|systemd-timedated|NetworkManager|fwupd|virtqemud|libvirtd|packagekit)" | \
        wc -l)
    
    if [[ "$failures" -gt 0 ]]; then
        log "Found $failures error log entries for monitored services in last 7 days" "WARN"
        return 1
    else
        log "No recent error events for monitored services"
        return 0
    fi
}

# Print results table
print_results() {
    echo ""
    echo "=========================================="
    echo "SERVICE HEALTH CHECK RESULTS"
    echo "=========================================="
    echo ""
    
    printf "%-40s %-12s %-50s\n" "SERVICE" "STATUS" "MESSAGE"
    printf "%-40s %-12s %-50s\n" "-------" "------" "-------"
    
    for service in "${!RESULTS[@]}"; do
        local result="${RESULTS[$service]}"
        local status="${result%%|*}"
        local remaining="${result#*|}"
        local message="${remaining%%|*}"
        remaining="${remaining#*|}"
        local details="${remaining%%|*}"
        local svc_type="${remaining##*|}"
        
        local status_display
        case "$status" in
            "PASS")     status_display="\033[32m[PASS]\033[0m" ;;
            "WARNING")  status_display="\033[33m[WARN]\033[0m" ;;
            "CRITICAL") status_display="\033[31m[FAIL]\033[0m" ;;
            *)          status_display="[$status]" ;;
        esac
        
        printf "%-40s " "$service"
        echo -en "$status_display"
        printf " %-50s\n" "$message"
        log "  $service: $status - $message - $details"
    done
    
    echo ""
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
log "Check Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log File: $LOG_FILE"
log ""

# Pre-flight checks
check_root
check_systemd

log "Starting daemon health checks..."
log ""

# Check each configured service
for service in "${!SERVICE_CONFIG[@]}"; do
    log "Checking: $service"
    check_service "$service"
done

# Check for crash events
log ""
check_crash_events
CRASH_RESULT=$?

# Print results
print_results

# Summary
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""
echo "Services Checked: ${#SERVICE_CONFIG[@]}"
echo "  Passed:   $PASS_COUNT"
echo "  Warnings: $WARNING_COUNT"  
echo "  Critical: $CRITICAL_COUNT"
echo ""

log "Summary: Passed=$PASS_COUNT, Warnings=$WARNING_COUNT, Critical=$CRITICAL_COUNT"

# Final verdict
if [[ $CRITICAL_COUNT -gt 0 ]]; then
    echo -e "\033[31mFAIL: $CRITICAL_COUNT critical issue(s) detected\033[0m"
    echo ""
    echo "RECOMMENDED ACTIONS:"
    echo "1. Run the Remediate_Linux_Daemons.sh script"
    echo "2. Check journalctl -xe for detailed error messages"
    echo "3. Verify package installation with: dnf list installed | grep <package>"
    echo ""
    log "Overall Status: CRITICAL" "ERROR"
    exit 2
elif [[ $WARNING_COUNT -gt 0 ]]; then
    echo -e "\033[33mWARNING: $WARNING_COUNT issue(s) may need attention\033[0m"
    echo ""
    echo "RECOMMENDATIONS:"
    echo "1. Run remediation script to attempt automatic fixes"
    echo "2. Review systemctl status <service> for details"
    echo ""
    log "Overall Status: WARNING" "WARN"
    exit 1
else
    echo -e "\033[32mPASS: All daemon services are healthy\033[0m"
    echo ""
    echo "NOTE: Services showing 'inactive' for D-Bus/socket activated"
    echo "services is normal - they activate on demand."
    echo ""
    log "Overall Status: PASS" "SUCCESS"
    exit 0
fi
