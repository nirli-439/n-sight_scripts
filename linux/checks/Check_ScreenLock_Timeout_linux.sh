#!/usr/bin/env bash
# =============================================================================
# Check_ScreenLock_Timeout_linux.sh - Verify enforced GNOME 15-minute lock
# =============================================================================
#
# SYNOPSIS:
#     Verifies the system dconf policy starts the GNOME idle lock at 15 minutes
#     and locks the keys so users cannot change them.
#
# DESCRIPTION:
#     Supports Ubuntu 22.04+ and Fedora 38+ with GNOME. It checks the deployed
#     dconf system database rather than a root or Session 0 user preference.
#
# EXIT CODES:
#     0    = OK
#     1002 = CRITICAL (policy missing or changed)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_ScreenLock_Timeout_linux.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_ScreenLock_Timeout_linux.sh" | sudo bash
#
# NOTES:
#     Pair with linux/tasks/Remediate_ScreenLock_Timeout_linux.sh.
# =============================================================================

set -o pipefail

readonly EXIT_CRITICAL=1002
readonly PROFILE=/etc/dconf/profile/user
readonly POLICY=/etc/dconf/db/local.d/00-screen-lock
readonly LOCKS=/etc/dconf/db/local.d/locks/00-screen-lock

if [[ $EUID -ne 0 ]]; then
    echo 'CRITICAL: Root privileges required'
    exit "$EXIT_CRITICAL"
fi

if [[ ! -x /usr/bin/dconf ]]; then
    echo 'CRITICAL: GNOME dconf is not installed'
    exit "$EXIT_CRITICAL"
fi

if grep -Fxq 'system-db:local' "$PROFILE" 2>/dev/null \
    && grep -Eq '^[[:space:]]*idle-delay[[:space:]]*=[[:space:]]*uint32[[:space:]]+900[[:space:]]*$' "$POLICY" 2>/dev/null \
    && grep -Eq '^[[:space:]]*lock-enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$POLICY" 2>/dev/null \
    && grep -Eq '^[[:space:]]*lock-delay[[:space:]]*=[[:space:]]*uint32[[:space:]]+0[[:space:]]*$' "$POLICY" 2>/dev/null \
    && grep -Fxq '/org/gnome/desktop/session/idle-delay' "$LOCKS" 2>/dev/null \
    && grep -Fxq '/org/gnome/desktop/screensaver/lock-enabled' "$LOCKS" 2>/dev/null \
    && grep -Fxq '/org/gnome/desktop/screensaver/lock-delay' "$LOCKS" 2>/dev/null; then
    echo 'OK: GNOME screen lock enforced after 15 minutes'
    exit 0
fi

echo 'CRITICAL: GNOME 15-minute screen-lock policy is missing or not enforced'
exit "$EXIT_CRITICAL"
