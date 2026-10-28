#!/usr/bin/env bash
# =============================================================================
# Remove_NSight_Agent_mac.sh - Remove the N-able N-sight macOS monitoring agent
# =============================================================================
#
# Uses the agent's supported `rmmagentd uninstall` command first, then removes
# only residual rmmagentd files and verifies none remain. It deliberately does
# NOT remove Take Control/MSP Anywhere, other N-able products, or script logs.
#
# Run locally: sudo bash Remove_NSight_Agent_mac.sh
# From repo:    curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Remove_NSight_Agent_mac.sh" | sudo bash
#
# The current N-sight connection will disconnect during removal.
# =============================================================================

set -o pipefail

readonly EXIT_SUCCESS=0 EXIT_CRITICAL=1002
readonly AGENT_DIR=/usr/local/rmmagent AGENT_BIN=/usr/local/rmmagent/rmmagentd
readonly LOG_DIR=/var/log/nsight LOG_FILE="${LOG_DIR}/RemoveNSightAgent_$(date +%Y%m%d_%H%M%S).log"
REMOVED=()

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
    local code="$1" title="$2" message="$3"
    echo "$message"
    popup "$title" "$message"
    exit "$code"
}

record_removed() {
    local path="$1" item
    for item in "${REMOVED[@]}"; do [[ "$item" == "$path" ]] && return; done
    REMOVED+=("$path")
}

remove_path() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    rm -rf "$path" || return 1
    [[ -e "$path" || -L "$path" ]] && return 1
    record_removed "$path"
    log "Removed: $path"
}

[[ $EUID -eq 0 ]] || finish "$EXIT_CRITICAL" "N-sight removal failed" "N-sight agent was not removed: run this script as an administrator."

# Save every existing agent path for the completion dialog before the official
# uninstaller removes it.
[[ -e "$AGENT_DIR" || -L "$AGENT_DIR" ]] && record_removed "$AGENT_DIR"
[[ -e /usr/local/bin/rmmagentd || -L /usr/local/bin/rmmagentd ]] && record_removed /usr/local/bin/rmmagentd
while IFS= read -r plist; do record_removed "$plist"; done < <(grep -rl "rmmagentd" /Library/LaunchDaemons 2>/dev/null)

# N-able's agent-provided uninstall operation; failures fall through to the
# residual cleanup and verification below because damaged agents may not run it.
if [[ -x "$AGENT_BIN" ]]; then
    log "Running supported agent uninstall command"
    "$AGENT_BIN" uninstall >>"$LOG_FILE" 2>&1 || log "rmmagentd uninstall returned non-zero; cleaning residual files"
fi

# Only LaunchDaemons explicitly containing the monitoring-agent binary match.
while IFS= read -r plist; do
    log "Stopping LaunchDaemon: $plist"
    launchctl bootout system "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
    remove_path "$plist" || finish "$EXIT_CRITICAL" "N-sight removal failed" "N-sight agent was not fully removed. Could not remove: $plist"
done < <(grep -rl "rmmagentd" /Library/LaunchDaemons 2>/dev/null)

pgrep -x rmmagentd >/dev/null 2>&1 && pkill -TERM -x rmmagentd 2>/dev/null || true
sleep 2
pgrep -x rmmagentd >/dev/null 2>&1 && pkill -KILL -x rmmagentd 2>/dev/null || true

remove_path "$AGENT_DIR" || finish "$EXIT_CRITICAL" "N-sight removal failed" "N-sight agent was not fully removed. Could not remove: $AGENT_DIR"
remove_path /usr/local/bin/rmmagentd || finish "$EXIT_CRITICAL" "N-sight removal failed" "N-sight agent was not fully removed. Could not remove: /usr/local/bin/rmmagentd"

# Remove only installer receipts whose file list includes rmmagentd.
while IFS= read -r receipt; do
    pkgutil --files "$receipt" 2>/dev/null | grep -qx '.*rmmagentd' || continue
    pkgutil --forget "$receipt" >/dev/null 2>&1 || log "Could not forget receipt: $receipt"
done < <(pkgutil --pkgs 2>/dev/null)

if pgrep -x rmmagentd >/dev/null 2>&1 || [[ -e "$AGENT_BIN" || -e /usr/local/bin/rmmagentd ]] || grep -rlq "rmmagentd" /Library/LaunchDaemons 2>/dev/null; then
    finish "$EXIT_CRITICAL" "N-sight removal failed" "N-sight agent was not fully removed. Check: $LOG_FILE"
fi

paths=$(printf '%s\n' "${REMOVED[@]}")
[[ -n "$paths" ]] || paths="No residual agent paths were present."
finish "$EXIT_SUCCESS" "N-sight removed" "$(printf 'N-sight agent was removed successfully.\n\nRemoved paths:\n%s\nReady for a fresh install.' "$paths")"
