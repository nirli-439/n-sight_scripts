#!/usr/bin/env bash
# =============================================================================
# Remediate_ScreenLock_Timeout_mac.sh - Enforce a 15-minute macOS screen lock
# =============================================================================
#
# SYNOPSIS:
#     Sets each local user's screen saver idle time to 15 minutes and requires
#     a password immediately when the screen saver resumes.
#
# EXIT CODES:
#     0    = configured and verified
#     1001 = WARNING (no local user homes to configure)
#     1002 = CRITICAL (not root or verification failed)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Remediate_ScreenLock_Timeout_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Remediate_ScreenLock_Timeout_mac.sh" | sudo bash
#
# NOTES:
#     Pair with macos/checks/Check_ScreenLock_Timeout_mac.sh.
# =============================================================================

set -o pipefail

readonly IDLE_SECONDS=900
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Root privileges required"
    exit "$EXIT_CRITICAL"
fi

users=()
for home in /Users/*; do
    [[ -d "$home/Library" ]] || continue
    user=$(basename "$home")
    case "$user" in Shared|Guest|.localized) continue ;; esac
    users+=("$user")
done

if [[ ${#users[@]} -eq 0 ]]; then
    echo "WARNING: No local user homes to configure"
    exit "$EXIT_WARNING"
fi

failed=()
for user in "${users[@]}"; do
    if ! /usr/bin/sudo -u "$user" /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int "$IDLE_SECONDS" \
        || ! /usr/bin/sudo -u "$user" /usr/bin/defaults write com.apple.screensaver askForPassword -int 1 \
        || ! /usr/bin/sudo -u "$user" /usr/bin/defaults write com.apple.screensaver askForPasswordDelay -int 0; then
        failed+=("$user")
        continue
    fi

    idle=$(/usr/bin/sudo -u "$user" /usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || true)
    ask=$(/usr/bin/sudo -u "$user" /usr/bin/defaults read com.apple.screensaver askForPassword 2>/dev/null || true)
    delay=$(/usr/bin/sudo -u "$user" /usr/bin/defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || true)
    [[ "$idle" == "$IDLE_SECONDS" && "$ask" == "1" && "$delay" == "0" ]] || failed+=("$user")
done

if [[ ${#failed[@]} -eq 0 ]]; then
    echo "OK: Screen lock set to 15 minutes with an immediate password for ${#users[@]} user(s)"
    exit 0
fi

echo "CRITICAL: Could not set or verify screen lock for: ${failed[*]}"
exit "$EXIT_CRITICAL"
