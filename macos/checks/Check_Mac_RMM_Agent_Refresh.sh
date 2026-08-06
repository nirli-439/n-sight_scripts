#!/usr/bin/env bash
# =============================================================================
# Check_Mac_RMM_Agent_Refresh.sh — N-sight Mac agent full refresh (24x7 check)
# =============================================================================
#
# SYNOPSIS:
#     Clears stuck automated tasks, syncs with the dashboard, and queues
#     24x7, DSC, and asset scans — same behavior as the former task script.
#
# DESCRIPTION:
#     Intended as a Shell 24x7 check or scheduled automated task body:
#     1) Locates rmmagentd
#     2) Ensures the agent daemon is running (starts if needed)
#     3) task-list (logged)
#     4) task-cancel --all
#     5) sync
#     6) scan --247, --dsc, --assets
#
#     Verbose steps go to /var/log/nsight only; stdout stays short for the
#     N-sight dashboard (first line ~255 chars).
#
#     N-sight default check timeout is 60s; this script can exceed that when
#     the agent is slow — raise the check timeout in the dashboard if needed
#     (up to 3600s per N-sight limits).
#
# EXIT CODES:
#     0    = Success (sync and all scans succeeded; agent was already up)
#     1001 = Warning (agent was restarted and recovered, or partial failures)
#     1002 = Critical (binary not found, or not root)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Mac_RMM_Agent_Refresh.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Mac_RMM_Agent_Refresh.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.3 (logic aligned with former Refresh_RMM_Agent_mac.sh v1.2)
#     Requires: root
#     Platform: macOS 10.15+
#
#     N-Sight Monitoring:
#     - Process Check: rmmagentd
#     - LaunchDaemon: pattern under /Library/LaunchDaemons (rmmagent / n-able)
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Mac RMM Agent Refresh Check"
readonly SCRIPT_VERSION="1.3"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/RefreshRMMAgent_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

readonly AGENT_BINARY_PATHS=(
    "/usr/local/rmmagent/rmmagentd"
    "/usr/local/bin/rmmagentd"
)

readonly DAEMON_START_WAIT=5

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" >>"$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Not root" "ERROR"
        echo "CRITICAL: Root privileges required for Mac RMM agent refresh check"
        exit $EXIT_CRITICAL
    fi
}

find_agent_binary() {
    local path
    for path in "${AGENT_BINARY_PATHS[@]}"; do
        if [[ -f "$path" && -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    local which_path
    which_path=$(command -v rmmagentd 2>/dev/null)
    if [[ -n "$which_path" ]]; then
        echo "$which_path"
        return 0
    fi
    return 1
}

find_launchdaemon_plist() {
    local f
    for f in /Library/LaunchDaemons/*.plist; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f")" in
            *rmmagent* | *n-able* | *nable* | *monitoring*agent*)
                echo "$f"
                return 0
                ;;
        esac
    done
    local plist
    plist=$(grep -rl "rmmagentd" /Library/LaunchDaemons 2>/dev/null | head -1)
    if [[ -n "$plist" ]]; then
        echo "$plist"
        return 0
    fi
    return 1
}

get_launchdaemon_label() {
    /usr/libexec/PlistBuddy -c "Print :Label" "$1" 2>/dev/null
}

is_agent_running() {
    pgrep -x rmmagentd >/dev/null 2>&1
}

ensure_agent_running() {
    local agent_bin="$1"

    if is_agent_running; then
        log "Agent daemon is already running (PID: $(pgrep -x rmmagentd))"
        return 0
    fi

    log "Agent daemon is NOT running — attempting to start..." "WARNING"

    local plist
    plist=$(find_launchdaemon_plist)

    if [[ -n "$plist" ]]; then
        local label
        label=$(get_launchdaemon_label "$plist")
        log "Found LaunchDaemon plist: $plist (label: ${label:-unknown})"
        launchctl unload "$plist" 2>/dev/null || true
        sleep 1
        log "Loading agent via launchctl..."
        launchctl load "$plist" 2>/dev/null
        sleep "$DAEMON_START_WAIT"
        if is_agent_running; then
            log "Agent started successfully via launchctl"
            return 0
        fi
        log "launchctl load did not start the agent — falling back to serve --background" "WARNING"
    fi

    log "Starting agent via: $agent_bin serve --background"
    "$agent_bin" serve --background 2>/dev/null
    sleep "$DAEMON_START_WAIT"

    if is_agent_running; then
        log "Agent started successfully via serve --background"
        return 0
    fi

    log "Failed to start the agent daemon" "ERROR"
    return 1
}

run_agent_cmd() {
    local agent_bin="$1"
    shift
    local cmd_label="$*"
    log "Running: rmmagentd $cmd_label"
    local output exit_code
    output=$("$agent_bin" "$@" 2>&1)
    exit_code=$?
    if [[ -n "$output" ]]; then
        while IFS= read -r line; do
            log "  $line"
        done <<<"$output"
    fi
    return $exit_code
}

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Hostname: $(hostname)"
log "macOS: $(sw_vers -productName 2>/dev/null || echo 'macOS') $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
log "User: $(whoami)"
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log: $LOG_FILE"
log ""

check_root

log "Step 1: Locating rmmagentd binary..."
AGENT_BIN=$(find_agent_binary)
if [[ -z "$AGENT_BIN" ]]; then
    log "rmmagentd binary not found" "ERROR"
    log "Searched: ${AGENT_BINARY_PATHS[*]}" "ERROR"
    echo "CRITICAL: rmmagentd binary not found — is the N-Sight agent installed?"
    exit $EXIT_CRITICAL
fi

log "Binary found: $AGENT_BIN"
AGENT_VERSION=$("$AGENT_BIN" --version 2>&1 | head -1 || echo "Unknown")
log "Version: $AGENT_VERSION"
log ""

log "Step 2: Checking agent daemon status..."
AGENT_WAS_DOWN=false
if ! ensure_agent_running "$AGENT_BIN"; then
    log "Could not confirm agent is running — commands may still work if binary is functional" "WARNING"
    AGENT_WAS_DOWN=true
else
    if ! is_agent_running; then
        AGENT_WAS_DOWN=true
    fi
fi
log ""

log "Step 3: Listing current automated task queue..."
run_agent_cmd "$AGENT_BIN" task-list
log ""

log "Step 4: Cancelling all automated tasks to clear queue..."
run_agent_cmd "$AGENT_BIN" task-cancel --all
log ""

log "Step 5: Synchronising configuration with dashboard..."
SYNC_OK=false
if run_agent_cmd "$AGENT_BIN" sync; then
    log "Sync completed successfully" "SUCCESS"
    SYNC_OK=true
else
    log "Sync returned non-zero — dashboard may be unreachable" "WARNING"
fi
log ""

log "Step 6: Running all scan types..."
SCAN_247_OK=false
SCAN_DSC_OK=false
SCAN_ASSETS_OK=false

log "  6a: 24x7 check (--247)..."
if run_agent_cmd "$AGENT_BIN" scan --247; then
    log "  24x7 scan queued/completed" "SUCCESS"
    SCAN_247_OK=true
else
    log "  24x7 scan failed" "WARNING"
fi

log "  6b: Daily Safety Check (--dsc)..."
if run_agent_cmd "$AGENT_BIN" scan --dsc; then
    log "  DSC scan queued/completed" "SUCCESS"
    SCAN_DSC_OK=true
else
    log "  DSC scan failed" "WARNING"
fi

log "  6c: Asset scan (--assets)..."
if run_agent_cmd "$AGENT_BIN" scan --assets; then
    log "  Asset scan queued/completed" "SUCCESS"
    SCAN_ASSETS_OK=true
else
    log "  Asset scan failed" "WARNING"
fi
log ""

log "=========================================="
log "Refresh Summary"
log "=========================================="

FAIL_COUNT=0
[[ "$SYNC_OK" == false ]] && FAIL_COUNT=$((FAIL_COUNT + 1))
[[ "$SCAN_247_OK" == false ]] && FAIL_COUNT=$((FAIL_COUNT + 1))
[[ "$SCAN_DSC_OK" == false ]] && FAIL_COUNT=$((FAIL_COUNT + 1))
[[ "$SCAN_ASSETS_OK" == false ]] && FAIL_COUNT=$((FAIL_COUNT + 1))

HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
DAEMON_LINE="Running (PID: $(pgrep -x rmmagentd))"
is_agent_running || DAEMON_LINE="Not running"

log "Daemon: $DAEMON_LINE | Sync=$SYNC_OK | 247=$SCAN_247_OK dsc=$SCAN_DSC_OK assets=$SCAN_ASSETS_OK | fails=$FAIL_COUNT"

if [[ $FAIL_COUNT -eq 0 ]] && [[ "$AGENT_WAS_DOWN" == false ]]; then
    log "All refresh operations completed successfully" "SUCCESS"
    echo "OK: Mac agent refresh — sync and scans succeeded | $AGENT_VERSION | $HOST_SHORT"
    exit $EXIT_SUCCESS
elif [[ $FAIL_COUNT -eq 0 ]] && [[ "$AGENT_WAS_DOWN" == true ]]; then
    log "All refresh operations completed (agent was restarted)" "SUCCESS"
    echo "WARNING: Mac agent was restarted then sync and scans succeeded | $HOST_SHORT | log $LOG_FILE"
    exit $EXIT_WARNING
else
    log "$FAIL_COUNT operation(s) failed" "WARNING"
    echo "WARNING: Mac agent refresh partial fail ($FAIL_COUNT) | $HOST_SHORT | log $LOG_FILE"
    exit $EXIT_WARNING
fi
