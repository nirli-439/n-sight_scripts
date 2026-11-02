#!/usr/bin/env bash
# =============================================================================
# Confirm_NSight_Agent_mac.sh - Verify a fresh N-able N-sight Mac agent install
# =============================================================================
# Run locally: sudo bash Confirm_NSight_Agent_mac.sh
# Double-click Confirm_NSight_Agent_mac.command for a macOS admin-login prompt.
# =============================================================================

set -o pipefail

readonly EXIT_SUCCESS=0 EXIT_CRITICAL=1002
readonly AGENT_BIN=/usr/local/rmmagent/rmmagentd
readonly LOG_DIR=/var/log/nsight LOG_FILE="${LOG_DIR}/ConfirmNSightAgent_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR" 2>/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE"; }

popup() {
    local title="$1" message="$2" user uid
    user=$(stat -f%Su /dev/console 2>/dev/null)
    [[ -n "$user" && "$user" != root && "$user" != loginwindow ]] || return 0
    uid=$(id -u "$user" 2>/dev/null) || return 0
    launchctl asuser "$uid" sudo -u "$user" /usr/bin/osascript \
        -e 'on run argv' \
        -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon note' \
        -e 'end run' -- "$title" "$message" >/dev/null 2>&1 || true
}

finish() {
    echo "$3"
    popup "$2" "$3"
    exit "$1"
}

[[ $EUID -eq 0 ]] || finish "$EXIT_CRITICAL" "N-sight check failed" "Run this check as an administrator."
[[ -x "$AGENT_BIN" ]] || finish "$EXIT_CRITICAL" "N-sight check failed" "N-sight is not installed: $AGENT_BIN is missing."
pgrep -x rmmagentd >/dev/null 2>&1 || finish "$EXIT_CRITICAL" "N-sight check failed" "N-sight is installed but rmmagentd is not running. Restart or reinstall the agent."

PLIST=$(grep -rl "rmmagentd" /Library/LaunchDaemons 2>/dev/null | head -1)
[[ -n "$PLIST" ]] || finish "$EXIT_CRITICAL" "N-sight check failed" "N-sight is running but its LaunchDaemon was not found. Reinstall the agent."

log "Running agent sync"
"$AGENT_BIN" sync >>"$LOG_FILE" 2>&1 || finish "$EXIT_CRITICAL" "N-sight check failed" "rmmagentd is running but cannot sync with N-sight. Check network/site installer. Log: $LOG_FILE"

VERSION=$("$AGENT_BIN" --version 2>/dev/null | head -1)
finish "$EXIT_SUCCESS" "N-sight is working" "$(printf 'N-sight agent is installed, running, and synced successfully.\n\nAgent: %s\nLaunchDaemon: %s\nVersion: %s' "$AGENT_BIN" "$PLIST" "${VERSION:-unknown}")"
