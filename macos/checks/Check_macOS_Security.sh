#!/bin/bash
# Check_macOS_Security.sh - Security compliance check for macOS
# For N-Sight RMM deployment
#
# SYNOPSIS:
#   Checks critical macOS security settings:
#   - System Integrity Protection (SIP) enabled
#   - Gatekeeper enabled
#   - No unsigned kernel extensions loaded
#
# DESCRIPTION:
#   This security monitoring script verifies that key macOS security
#   features are properly enabled:
#   
#   1. SIP (System Integrity Protection) - Prevents modification of
#      system files and processes, blocks unsigned kernel extensions
#   
#   2. Gatekeeper - Enforces code signing and notarization for apps,
#      blocks unverified software from running
#   
#   3. Unsigned Kernel Extensions - Checks for any third-party kexts
#      that are not properly signed (security risk)
#
#   Designed for N-Sight RMM security compliance monitoring on macOS.
#
# EXIT CODES:
#   0    = PASS (All security checks passed)
#   1001 = WARNING (Some checks passed, minor issues)
#   1002 = CRITICAL (Security features disabled)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_macOS_Security.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_macOS_Security.sh" | sudo bash
#
# NOTES:
#   Author: IT Admin
#   Version: 1.0
#   Requires: root privileges (for full kext checking)
#   Platform: macOS 10.13+ (High Sierra and later)

# ============================================================================
# CONFIGURATION
# ============================================================================
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/macOS_SecurityCheck_$(date +%Y%m%d_%H%M%S).log"

# Track overall status
OVERALL_STATUS=0
SIP_STATUS="UNKNOWN"
GATEKEEPER_STATUS="UNKNOWN"
KEXT_STATUS="UNKNOWN"
UNSIGNED_KEXTS=""

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" | tee -a "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "WARNING: Running without root privileges - some checks may be limited" "WARNING"
        return 1
    fi
    return 0
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

get_macos_name() {
    sw_vers -productName 2>/dev/null || echo "macOS"
}

# Check System Integrity Protection (SIP)
check_sip() {
    log "Checking System Integrity Protection (SIP)..."
    
    local sip_output
    sip_output=$(csrutil status 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log "Failed to check SIP status - csrutil command failed" "ERROR"
        SIP_STATUS="ERROR"
        return 2
    fi
    
    log "SIP Output: $sip_output"
    
    # Check if SIP is enabled
    if echo "$sip_output" | grep -qi "enabled"; then
        # Check for partial SIP (some components disabled)
        if echo "$sip_output" | grep -qi "disabled"; then
            log "SIP is partially enabled (some protections disabled)" "WARNING"
            SIP_STATUS="PARTIAL"
            return 1
        else
            log "SIP is fully enabled"
            SIP_STATUS="ENABLED"
            return 0
        fi
    elif echo "$sip_output" | grep -qi "disabled"; then
        log "SIP is DISABLED - Critical security risk!" "ERROR"
        SIP_STATUS="DISABLED"
        return 2
    else
        log "Unable to determine SIP status" "WARNING"
        SIP_STATUS="UNKNOWN"
        return 1
    fi
}

# Check Gatekeeper status
check_gatekeeper() {
    log "Checking Gatekeeper status..."
    
    local gk_output
    gk_output=$(spctl --status 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log "Failed to check Gatekeeper status - spctl command failed" "ERROR"
        GATEKEEPER_STATUS="ERROR"
        return 2
    fi
    
    log "Gatekeeper Output: $gk_output"
    
    # Check Gatekeeper assessment status
    if echo "$gk_output" | grep -qi "assessments enabled"; then
        log "Gatekeeper is enabled"
        GATEKEEPER_STATUS="ENABLED"
        return 0
    elif echo "$gk_output" | grep -qi "assessments disabled"; then
        log "Gatekeeper is DISABLED - Critical security risk!" "ERROR"
        GATEKEEPER_STATUS="DISABLED"
        return 2
    else
        log "Unable to determine Gatekeeper status" "WARNING"
        GATEKEEPER_STATUS="UNKNOWN"
        return 1
    fi
}

# Check for unsigned kernel extensions
check_unsigned_kexts() {
    log "Checking for unsigned kernel extensions..."
    
    # On modern macOS (10.13+), most kexts should be signed
    # Apple kexts are in /System/Library/Extensions
    # Third-party kexts are in /Library/Extensions
    
    local kext_count=0
    local unsigned_count=0
    UNSIGNED_KEXTS=""
    
    # Check if kextstat is available (deprecated in newer macOS but still works)
    if command -v kextstat &>/dev/null; then
        # Get list of loaded third-party kexts (excluding Apple's)
        local third_party_kexts
        third_party_kexts=$(kextstat 2>/dev/null | grep -v "com.apple" | tail -n +2)
        
        if [ -n "$third_party_kexts" ]; then
            log "Found third-party kernel extensions loaded"
            
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    local bundle_id
                    bundle_id=$(echo "$line" | awk '{print $6}')
                    
                    if [ -n "$bundle_id" ]; then
                        kext_count=$((kext_count + 1))
                        log "Third-party kext: $bundle_id"
                        
                        # Check signature using codesign
                        # Find the kext bundle path
                        local kext_path=""
                        if [ -d "/Library/Extensions/${bundle_id}.kext" ]; then
                            kext_path="/Library/Extensions/${bundle_id}.kext"
                        else
                            # Try to find by bundle ID
                            kext_path=$(find /Library/Extensions -name "*.kext" -exec sh -c 'defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null | grep -q "'"$bundle_id"'" && echo "$1"' _ {} \; 2>/dev/null | head -1)
                        fi
                        
                        if [ -n "$kext_path" ] && [ -d "$kext_path" ]; then
                            local sig_status
                            sig_status=$(codesign -v "$kext_path" 2>&1)
                            local sig_result=$?
                            
                            if [ $sig_result -ne 0 ]; then
                                unsigned_count=$((unsigned_count + 1))
                                UNSIGNED_KEXTS="${UNSIGNED_KEXTS}${bundle_id} "
                                log "UNSIGNED kext detected: $bundle_id at $kext_path" "WARNING"
                            else
                                log "Kext is signed: $bundle_id"
                            fi
                        fi
                    fi
                fi
            done <<< "$third_party_kexts"
        fi
    fi
    
    # Also check SystemExtensions (newer replacement for kexts)
    if command -v systemextensionsctl &>/dev/null; then
        log "Checking System Extensions..."
        local sysext_list
        sysext_list=$(systemextensionsctl list 2>/dev/null)
        if [ -n "$sysext_list" ]; then
            log "System Extensions Output:"
            echo "$sysext_list" | while read -r line; do
                log "  $line"
            done
        fi
    fi
    
    log "Third-party kext count: $kext_count"
    log "Unsigned kext count: $unsigned_count"
    
    if [ $unsigned_count -gt 0 ]; then
        log "Found $unsigned_count unsigned kernel extension(s)" "ERROR"
        KEXT_STATUS="UNSIGNED_FOUND"
        return 2
    elif [ $kext_count -gt 0 ]; then
        log "All $kext_count third-party kext(s) are properly signed"
        KEXT_STATUS="ALL_SIGNED"
        return 0
    else
        log "No third-party kernel extensions loaded"
        KEXT_STATUS="NONE"
        return 0
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "macOS Security Compliance Check"
log "=========================================="
log "Hostname: $(hostname)"
log "macOS Version: $(get_macos_name) $(get_macos_version)"
log "Build: $(sw_vers -buildVersion 2>/dev/null || echo 'Unknown')"
log "Check Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log File: $LOG_FILE"
log "Running as user: $(whoami)"

# Check for root (optional but recommended)
IS_ROOT=0
if check_root; then
    IS_ROOT=1
fi

log ""
log "=========================================="
log "Running Security Checks"
log "=========================================="

# Check 1: System Integrity Protection
log ""
log "--- Check 1: System Integrity Protection (SIP) ---"
check_sip
SIP_RESULT=$?
if [ $SIP_RESULT -eq 2 ]; then
    OVERALL_STATUS=2
elif [ $SIP_RESULT -eq 1 ] && [ $OVERALL_STATUS -lt 1 ]; then
    OVERALL_STATUS=1
fi

# Check 2: Gatekeeper
log ""
log "--- Check 2: Gatekeeper ---"
check_gatekeeper
GK_RESULT=$?
if [ $GK_RESULT -eq 2 ]; then
    OVERALL_STATUS=2
elif [ $GK_RESULT -eq 1 ] && [ $OVERALL_STATUS -lt 1 ]; then
    OVERALL_STATUS=1
fi

# Check 3: Unsigned Kernel Extensions
log ""
log "--- Check 3: Unsigned Kernel Extensions ---"
check_unsigned_kexts
KEXT_RESULT=$?
if [ $KEXT_RESULT -eq 2 ]; then
    OVERALL_STATUS=2
elif [ $KEXT_RESULT -eq 1 ] && [ $OVERALL_STATUS -lt 1 ]; then
    OVERALL_STATUS=1
fi

# ============================================================================
# FINAL RESULTS
# ============================================================================

log ""
log "=========================================="
log "Security Check Results"
log "=========================================="

echo ""
echo "=========================================="
echo "macOS Security Check Results"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "macOS: $(get_macos_name) $(get_macos_version)"
echo ""
echo "Security Status:"
echo "  SIP (System Integrity Protection): $SIP_STATUS"
echo "  Gatekeeper: $GATEKEEPER_STATUS"
echo "  Unsigned Kernel Extensions: $KEXT_STATUS"
echo ""

if [ $OVERALL_STATUS -eq 0 ]; then
    log "OVERALL STATUS: PASS - All security checks passed"
    echo "PASS: All macOS security checks passed"
    echo ""
    echo "All critical security features are properly configured."
    exit 0
elif [ $OVERALL_STATUS -eq 1 ]; then
    log "OVERALL STATUS: WARNING - Some security issues detected" "WARNING"
    echo "WARNING: Minor security issues detected"
    echo ""
    echo "Review the following:"
    [ "$SIP_STATUS" = "PARTIAL" ] && echo "  - SIP is only partially enabled"
    [ "$SIP_STATUS" = "UNKNOWN" ] && echo "  - Unable to verify SIP status"
    [ "$GATEKEEPER_STATUS" = "UNKNOWN" ] && echo "  - Unable to verify Gatekeeper status"
    echo ""
    echo "Remediation:"
    echo "  - SIP: Reboot to Recovery Mode (Cmd+R), open Terminal, run: csrutil enable"
    echo "  - Gatekeeper: Run: sudo spctl --master-enable"
    exit 1001
else
    log "OVERALL STATUS: CRITICAL - Security features disabled!" "ERROR"
    echo "CRITICAL: Security features are disabled!"
    echo ""
    echo "Issues Found:"
    [ "$SIP_STATUS" = "DISABLED" ] && echo "  - System Integrity Protection is DISABLED"
    [ "$GATEKEEPER_STATUS" = "DISABLED" ] && echo "  - Gatekeeper is DISABLED"
    [ "$KEXT_STATUS" = "UNSIGNED_FOUND" ] && echo "  - Unsigned kernel extensions: $UNSIGNED_KEXTS"
    echo ""
    echo "Remediation Required:"
    [ "$SIP_STATUS" = "DISABLED" ] && echo "  - SIP: Reboot to Recovery Mode (Cmd+R), open Terminal, run: csrutil enable"
    [ "$GATEKEEPER_STATUS" = "DISABLED" ] && echo "  - Gatekeeper: Run: sudo spctl --master-enable"
    [ "$KEXT_STATUS" = "UNSIGNED_FOUND" ] && echo "  - Remove or replace unsigned kernel extensions from /Library/Extensions"
    exit 1002
fi
