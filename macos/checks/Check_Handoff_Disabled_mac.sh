#!/usr/bin/env bash
# =============================================================================
# Check_Handoff_Disabled_mac.sh - Verify Handoff (Continuity) is disabled
# =============================================================================
#
# SYNOPSIS:
#     Confirms Handoff is off for each local user by reading
#     com.apple.coreservices.useractivityd preferences.
#
# DESCRIPTION:
#     Handoff uses ActivityAdvertisingAllowed and ActivityReceivingAllowed.
#     Both must be false for compliance. Missing keys are treated as non-compliant
#     (Handoff defaults to enabled when unset).
#
#     Scope: macOS only. iPhone/iPad require MDM (Restrictions), not this script.
#
# EXIT CODES:
#     0    = OK (Handoff disabled for all checked users)
#     1001 = WARNING (no user homes to evaluate, or read errors)
#     1002 = CRITICAL (Handoff enabled or not explicitly disabled for a user)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Handoff_Disabled_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Handoff_Disabled_mac.sh" | sudo bash
#
# NOTES:
#     Pair with macos/tasks/Remediate_Disable_Handoff_mac.sh for remediation.
#     Operational keys per Apple Continuity / useractivityd domain (community-
#     documented defaults; verify on your macOS version in a lab).
#
# REFERENCES:
#     N-able Script Writing Guidelines:
#     https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Check Handoff Disabled"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/CheckHandoff_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

readonly PREFS_DOMAIN="com.apple.coreservices.useractivityd"

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

write_summary() {
    echo ""
    echo "${1}: ${2}"
}

# Returns 0 if value means "off", 1 if "on" or unknown
_is_pref_off() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off) return 0 ;;
        *) return 1 ;;
    esac
}

# Returns 0 if Handoff is disabled for user, 1 if enabled / missing / error
handoff_disabled_for_user() {
    local username="$1"
    local adv recv

    adv=$(sudo -u "$username" defaults read "$PREFS_DOMAIN" ActivityAdvertisingAllowed 2>/dev/null) || return 1
    recv=$(sudo -u "$username" defaults read "$PREFS_DOMAIN" ActivityReceivingAllowed 2>/dev/null) || return 1

    if _is_pref_off "$adv" && _is_pref_off "$recv"; then
        return 0
    fi
    return 1
}

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "Hostname: $(hostname)"
log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
log "=========================================="

if [[ $EUID -ne 0 ]]; then
    log "Not running as root; user defaults may be incomplete" "WARNING"
fi

any_user=false
failed_users=()

for user_home in /Users/*; do
    [[ -d "$user_home" ]] || continue
    username=$(basename "$user_home")
    case "$username" in
        Shared|Guest|.localized) continue ;;
    esac
    [[ -d "${user_home}/Library" ]] || continue

    any_user=true
    if handoff_disabled_for_user "$username"; then
        log "User '$username': Handoff disabled (OK)"
    else
        log "User '$username': Handoff not disabled or prefs missing" "ERROR"
        failed_users+=("$username")
    fi
done

log "=========================================="
log "Summary"
log "=========================================="

if [[ "$any_user" == false ]]; then
    write_summary "WARNING" "No local user home directories evaluated"
    exit $EXIT_WARNING
fi

if [[ ${#failed_users[@]} -eq 0 ]]; then
    write_summary "OK" "Handoff disabled for all evaluated users"
    exit $EXIT_SUCCESS
fi

write_summary "CRITICAL" "Handoff not disabled for: ${failed_users[*]}"
echo "Run Remediate_Disable_Handoff_mac.sh"
exit $EXIT_CRITICAL
