#!/bin/bash
# =============================================================================
# Configure_Mac_Defaults_mac.sh - Helfy standard macOS settings (no imaging)
# =============================================================================
#
# SYNOPSIS:
#     macOS counterpart of the Windows "speed & focus tweaks" + USB defaults:
#     - Network time on; time zone Asia/Jerusalem ONLY if the Mac is still on
#       UTC/GMT (Setup Assistant normally set the right zone - never override it)
#     - Per local user: Hebrew keyboard added (kept English), file extensions
#       shown, no "recent apps" in the Dock, battery % in the menu bar,
#       Handoff off (same keys as Remediate_Disable_Handoff_mac.sh)
#     Idempotent; safe to re-run. Never touches Dock icons, security or updates.
#
# EXIT CODES:
#     0    = applied and verified for every user
#     1001 = WARNING (no user homes, or a non-critical item could not be set)
#     1002 = CRITICAL (not root, or per-user settings failed verification)
#
# EXECUTION:
#     sudo bash Configure_Mac_Defaults_mac.sh
#     curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Configure_Mac_Defaults_mac.sh" | sudo bash
# =============================================================================

set -o pipefail

readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002
readonly HEBREW_ID=-18432
readonly FALLBACK_TZ="${HELFY_TIMEZONE:-Asia/Jerusalem}"
readonly LOG_DIR=/var/log/nsight
readonly LOG_FILE="$LOG_DIR/ConfigureMacDefaults_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR" 2>/dev/null
log() { echo "$*"; echo "[$(date '+%H:%M:%S')] $*" >>"$LOG_FILE" 2>/dev/null; }

[[ $EUID -eq 0 ]] || { echo "CRITICAL: Root privileges required"; exit "$EXIT_CRITICAL"; }

warn=0

# --- Machine: clock -----------------------------------------------------------
/usr/sbin/systemsetup -setusingnetworktime on >/dev/null 2>&1 || { log "WARN: could not enable network time"; warn=1; }
tz=$(/usr/bin/readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
case "$tz" in
    ''|UTC|GMT|Etc/UTC|Etc/GMT|Universal|Zulu)
        if /usr/sbin/systemsetup -settimezone "$FALLBACK_TZ" >/dev/null 2>&1 \
            && [[ "$(/usr/bin/readlink /etc/localtime)" == *"/$FALLBACK_TZ" ]]; then
            log "Time zone: was '${tz:-unset}', set to $FALLBACK_TZ"
        else
            log "WARN: could not set time zone $FALLBACK_TZ"; warn=1
        fi ;;
    *) log "Time zone: $tz (kept)" ;;
esac

# --- Per user -----------------------------------------------------------------
users=()
for home in /Users/*; do
    [[ -d "$home/Library/Preferences" ]] || continue
    user=$(basename "$home")
    case "$user" in Shared|Guest|.localized) continue ;; esac
    uid=$(id -u "$user" 2>/dev/null) || continue
    [[ $uid -ge 500 ]] || continue
    users+=("$user")
done
[[ ${#users[@]} -gt 0 ]] || { echo "WARNING: No local user homes to configure"; exit "$EXIT_WARNING"; }

as() { local u="$1"; shift; /usr/bin/sudo -u "$u" "$@"; }

failed=()
for user in "${users[@]}"; do
    ok=1
    as "$user" /usr/bin/defaults write NSGlobalDomain AppleShowAllExtensions -bool true || ok=0
    as "$user" /usr/bin/defaults write com.apple.dock show-recents -bool false || ok=0
    as "$user" /usr/bin/defaults write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false || ok=0
    as "$user" /usr/bin/defaults write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false || ok=0
    # Battery % (macOS 13+ Control Center key; harmless on desktops).
    as "$user" /usr/bin/defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true || true

    # Hebrew keyboard next to the existing layouts (takes effect after log out/in).
    if ! as "$user" /usr/bin/defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null | grep -q -- "$HEBREW_ID"; then
        as "$user" /usr/bin/defaults write com.apple.HIToolbox AppleEnabledInputSources -array-add \
            "<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>$HEBREW_ID</integer><key>KeyboardLayout Name</key><string>Hebrew</string></dict>" || ok=0
    fi

    # Verify.
    [[ "$(as "$user" /usr/bin/defaults read NSGlobalDomain AppleShowAllExtensions 2>/dev/null)" == 1 ]] || ok=0
    [[ "$(as "$user" /usr/bin/defaults read com.apple.dock show-recents 2>/dev/null)" == 0 ]] || ok=0
    [[ "$(as "$user" /usr/bin/defaults read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null)" == 0 ]] || ok=0
    as "$user" /usr/bin/defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null | grep -q -- "$HEBREW_ID" || ok=0

    if [[ $ok == 1 ]]; then
        log "User $user: OK"
        uid=$(id -u "$user")
        # Reload only this user's UI processes so changes show now (no logout).
        /usr/bin/pkill -x -U "$uid" Dock 2>/dev/null || true
        /usr/bin/pkill -x -U "$uid" Finder 2>/dev/null || true
        /usr/bin/pkill -x -U "$uid" sharingd 2>/dev/null || true
    else
        log "User $user: FAILED verification"; failed+=("$user")
    fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "CRITICAL: settings failed for: ${failed[*]} (log $LOG_FILE)"; exit "$EXIT_CRITICAL"
fi
if [[ $warn == 1 ]]; then
    echo "WARNING: user settings OK (${users[*]}); clock/time zone item failed (log $LOG_FILE)"; exit "$EXIT_WARNING"
fi
echo "OK: Mac settings applied for ${users[*]} (Hebrew keyboard active after next log in)"
exit 0
