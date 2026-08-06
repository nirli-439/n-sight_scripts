#!/usr/bin/env bash
# =============================================================================
# Remediate_Disable_Handoff_mac.sh - Disable Handoff (Continuity) on macOS
# =============================================================================
#
# SYNOPSIS:
#     Sets Handoff off for each local user, then verifies preferences.
#
# DESCRIPTION:
#     Idempotent: if Handoff is already disabled for all users, exits OK without
#     changes. Otherwise writes ActivityAdvertisingAllowed and
#     ActivityReceivingAllowed to false via defaults, refreshes sharingd, and
#     re-checks. Applies to user accounts under /Users (skips Shared/Guest).
#
#     Scope: macOS only. iPhone/iPad require MDM profile keys, not shell.
#
# EXIT CODES:
#     0    = OK (Handoff disabled and verified for all users)
#     1001 = WARNING (no user homes under /Users to configure)
#     1002 = CRITICAL (not root, defaults write/verify failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Remediate_Disable_Handoff_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Remediate_Disable_Handoff_mac.sh" | sudo bash
#
# NOTES:
#     Requires root. Pair with macos/checks/Check_Handoff_Disabled_mac.sh.
#
# REFERENCES:
#     N-able Script Writing Guidelines:
#     https://documentation.n-able.com/remote-management/userguide/Content/script_guide.htm
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Disable Handoff"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/RemediateHandoff_$(date +%Y%m%d_%H%M%S).log"

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Root required" "ERROR"
        write_summary "CRITICAL" "Run as root (sudo)"
        exit $EXIT_CRITICAL
    fi
}

_is_pref_off() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off) return 0 ;;
        *) return 1 ;;
    esac
}

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

disable_handoff_for_user() {
    local username="$1"

    if sudo -u "$username" defaults write "$PREFS_DOMAIN" ActivityAdvertisingAllowed -bool false \
        && sudo -u "$username" defaults write "$PREFS_DOMAIN" ActivityReceivingAllowed -bool false; then
        # Flush preference cache for this user (best effort)
        pkill -u "$username" cfprefsd 2>/dev/null || true
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

check_root

any_user=false
changed=false
declare -a usernames=()

for user_home in /Users/*; do
    [[ -d "$user_home" ]] || continue
    username=$(basename "$user_home")
    case "$username" in
        Shared|Guest|.localized) continue ;;
    esac
    [[ -d "${user_home}/Library" ]] || continue

    any_user=true
    usernames+=("$username")

    if handoff_disabled_for_user "$username"; then
        log "User '$username': already disabled — no change"
    else
        log "User '$username': disabling Handoff..."
        if disable_handoff_for_user "$username"; then
            changed=true
            log "User '$username': defaults write succeeded"
        else
            log "User '$username': defaults write failed" "ERROR"
        fi
    fi
done

if [[ "$any_user" == false ]]; then
    write_summary "WARNING" "No user homes under /Users to configure"
    exit $EXIT_WARNING
fi

if [[ "$changed" == true ]]; then
    log "Restarting sharingd (best effort)..."
    killall sharingd 2>/dev/null || true
    sleep 1
fi

log "Verifying..."
verify_ok=true
for username in "${usernames[@]}"; do
    if handoff_disabled_for_user "$username"; then
        log "Verify user '$username': OK"
    else
        log "Verify user '$username': FAILED" "ERROR"
        verify_ok=false
    fi
done

log "=========================================="
log "Done"
log "=========================================="

if [[ "$verify_ok" == true ]]; then
    write_summary "OK" "Handoff disabled for ${#usernames[@]} user(s)"
    exit $EXIT_SUCCESS
fi

write_summary "CRITICAL" "Handoff verify failed after remediation — inspect prefs or MDM conflict"
exit $EXIT_CRITICAL
