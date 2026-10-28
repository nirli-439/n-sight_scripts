#!/usr/bin/env bash
# =============================================================================
# Remediate_ScreenLock_Timeout_linux.sh - Enforce GNOME 15-minute screen lock
# =============================================================================
#
# SYNOPSIS:
#     Creates a locked dconf system policy that locks GNOME after 15 minutes.
#
# DESCRIPTION:
#     Supports Ubuntu 22.04+ and Fedora 38+ with GNOME. The dconf locks prevent
#     users changing the idle or password-lock settings in GNOME Settings.
#     Policy applies when users next log in.
#
# EXIT CODES:
#     0    = configured and compiled
#     1002 = CRITICAL (not root, dconf unavailable, or compile failed)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Remediate_ScreenLock_Timeout_linux.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tasks/Remediate_ScreenLock_Timeout_linux.sh" | sudo bash
#
# NOTES:
#     Pair with linux/checks/Check_ScreenLock_Timeout_linux.sh.
# =============================================================================

set -o pipefail
# System GNOME policy must remain readable when invoked by a private-umask menu.
umask 022

readonly EXIT_CRITICAL=1002
readonly PROFILE=/etc/dconf/profile/user
readonly POLICY_DIR=/etc/dconf/db/local.d
readonly POLICY="$POLICY_DIR/00-screen-lock"
readonly LOCKS_DIR="$POLICY_DIR/locks"
readonly LOCKS="$LOCKS_DIR/00-screen-lock"

if [[ $EUID -ne 0 ]]; then
    echo 'CRITICAL: Root privileges required'
    exit "$EXIT_CRITICAL"
fi

if [[ ! -x /usr/bin/dconf ]]; then
    echo 'CRITICAL: GNOME dconf is not installed'
    exit "$EXIT_CRITICAL"
fi

mkdir -p "$(dirname "$PROFILE")" "$POLICY_DIR" "$LOCKS_DIR" || {
    echo 'CRITICAL: Could not create dconf policy directories'
    exit "$EXIT_CRITICAL"
}

if [[ ! -f "$PROFILE" ]]; then
    printf 'user-db:user\nsystem-db:local\n' > "$PROFILE" || exit "$EXIT_CRITICAL"
elif ! grep -Fxq 'system-db:local' "$PROFILE"; then
    printf '\nsystem-db:local\n' >> "$PROFILE" || exit "$EXIT_CRITICAL"
fi

cat > "$POLICY" <<'EOF' || exit "$EXIT_CRITICAL"
[org/gnome/desktop/session]
idle-delay=uint32 900

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
EOF

cat > "$LOCKS" <<'EOF' || exit "$EXIT_CRITICAL"
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
EOF

chmod 755 /etc/dconf /etc/dconf/profile /etc/dconf/db "$POLICY_DIR" "$LOCKS_DIR" \
    && chmod 644 "$PROFILE" "$POLICY" "$LOCKS" || {
    echo 'CRITICAL: Cannot set readable system-policy permissions'
    exit "$EXIT_CRITICAL"
}

if ! /usr/bin/dconf update >/dev/null 2>&1; then
    echo 'CRITICAL: Could not compile GNOME dconf policy'
    exit "$EXIT_CRITICAL"
fi

echo 'OK: GNOME screen lock enforced after 15 minutes; users must log in again'
exit 0
