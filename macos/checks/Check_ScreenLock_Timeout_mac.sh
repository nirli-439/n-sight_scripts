#!/usr/bin/env bash
# =============================================================================
# Check_ScreenLock_Timeout_mac.sh - Verify a 15-minute macOS screen lock
# =============================================================================
#
# SYNOPSIS:
#     Confirms every local user starts the screen saver within 15 minutes and
#     requires a password immediately on resume.
#
# EXIT CODES:
#     0    = OK
#     1001 = WARNING (no local user homes to evaluate)
#     1002 = CRITICAL (screen lock policy is missing or non-compliant)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_ScreenLock_Timeout_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/checks/Check_ScreenLock_Timeout_mac.sh" | sudo bash
#
# NOTES:
#     Pair with macos/tasks/Remediate_ScreenLock_Timeout_mac.sh.
# =============================================================================

set -o pipefail

readonly MAX_IDLE_SECONDS=900
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
    echo "WARNING: No local user homes to evaluate"
    exit "$EXIT_WARNING"
fi

failed=()
for user in "${users[@]}"; do
    idle=$(/usr/bin/sudo -u "$user" /usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || true)
    ask=$(/usr/bin/sudo -u "$user" /usr/bin/defaults read com.apple.screensaver askForPassword 2>/dev/null || true)
    delay=$(/usr/bin/sudo -u "$user" /usr/bin/defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || true)

    if [[ "$idle" =~ ^[0-9]+$ && "$idle" -gt 0 && "$idle" -le "$MAX_IDLE_SECONDS" && "$ask" == "1" && "$delay" =~ ^[0-9]+$ && "$delay" -eq 0 ]]; then
        continue
    fi
    failed+=("$user")
done

if [[ ${#failed[@]} -eq 0 ]]; then
    echo "OK: Screen locks within 15 minutes with an immediate password for ${#users[@]} user(s)"
    exit 0
fi

echo "CRITICAL: 15-minute screen lock is not compliant for: ${failed[*]}"
exit "$EXIT_CRITICAL"
