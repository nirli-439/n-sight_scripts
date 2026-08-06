#!/usr/bin/env bash
# =============================================================================
# Check_Mac_RMM_Agent_SelfHeal.sh — N-sight Mac agent health + optional self-heal
# =============================================================================
#
# SYNOPSIS:
#     24x7-style check: verifies rmmagentd is present and running; optionally
#     recycles the LaunchDaemon and runs a dashboard sync when unhealthy.
#
# DESCRIPTION:
#     N-sight RMM on macOS uses rmmagentd under /usr/local/rmmagent/ (see N-able
#     Mac Agent install and Privacy & Security docs). This script:
#       1) Confirms the agent binary exists
#       2) Confirms the rmmagentd process is running
#       3) If not running and self-heal is enabled (default), unloads/reloads
#          the agent LaunchDaemon plist (same discovery pattern as
#          Check_Mac_RMM_Agent_Refresh.sh) or falls back to serve --background
#       4) Optionally runs rmmagentd sync after recovery
#
#     This script does NOT reset TCC / Full Disk Access / Accessibility.
#     Those require user action or MDM (Device Management for Apple); see:
#     https://documentation.n-able.com/remote-management/userguide/Content/install_mac_agent_access.htm
#
#     Self-heal is idempotent when the agent is already healthy.
#
# ENVIRONMENT:
#     NSIGHT_AGENT_SELF_HEAL   Set to 0 for detect-only (no restart). Default: 1
#     NSIGHT_AGENT_RUN_SYNC    Set to 0 to skip sync after heal. Default: 1
#
# EXIT CODES:
#     0    = PASS (agent healthy; no action or full recovery)
#     1001 = WARNING (agent running but sync failed, or heal ran but sync failed)
#     1002 = CRITICAL (binary missing, still down after heal, or not root)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Mac_RMM_Agent_SelfHeal.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/checks/Check_Mac_RMM_Agent_SelfHeal.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: root (N-sight Automated Task / check runs as root)
#     Platform: macOS 10.15+ (same agent layout as Check_Mac_RMM_Agent_Refresh.sh)
#
#     N-Sight Monitoring:
#     - Process Check: rmmagentd
#     - OSX Daemon Check: (discovered) e.g. com.rmm.rmmagent — see LaunchDaemons
#     - LaunchDaemon Path: /Library/LaunchDaemons/*.plist (pattern match rmmagentd)
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Mac RMM Agent Self-Heal Check"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/MacRmmAgentSelfHeal_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

readonly AGENT_BINARY_PATHS=(
    "/usr/local/rmmagent/rmmagentd"
    "/usr/local/bin/rmmagentd"
)

readonly DAEMON_START_WAIT=5

SELF_HEAL="${NSIGHT_AGENT_SELF_HEAL:-1}"
RUN_SYNC="${NSIGHT_AGENT_RUN_SYNC:-1}"

SYNC_OK=true

# ---------------------------------------------------------------------------
# Logging: keep stdout minimal (first lines matter for dashboard truncation).
# ---------------------------------------------------------------------------
log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" >>"$LOG_FILE" 2>/dev/null
}

mkdir -p "$LOG_DIR" 2>/dev/null
log "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
log "Hostname: $(hostname) macOS: $(sw_vers -productVersion 2>/dev/null)"
log "SELF_HEAL=$SELF_HEAL RUN_SYNC=$RUN_SYNC"

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
            *rmmagent* | *n-able* | *nable* | *monitoring*agent*) echo "$f"; return 0 ;;
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

recycle_agent_launchdaemon() {
    local agent_bin="$1"
    local plist label

    plist=$(find_launchdaemon_plist || true)
    if [[ -n "$plist" ]]; then
        label=$(get_launchdaemon_label "$plist")
        log "Recycling LaunchDaemon plist=$plist label=${label:-unknown}"
        launchctl unload "$plist" 2>/dev/null || true
        sleep 1
        launchctl load "$plist" 2>/dev/null || log "launchctl load returned non-zero" "WARN"
        sleep "$DAEMON_START_WAIT"
        if is_agent_running; then
            log "Agent running after launchctl load"
            return 0
        fi
        log "launchctl load did not start rmmagentd; trying serve --background" "WARN"
    else
        log "No LaunchDaemon plist matched; trying serve --background" "WARN"
    fi

    "$agent_bin" serve --background 2>/dev/null || true
    sleep "$DAEMON_START_WAIT"
    if is_agent_running; then
        log "Agent running after serve --background"
        return 0
    fi
    return 1
}

try_sync() {
    local agent_bin="$1"
    local out ec
    out=$("$agent_bin" sync 2>&1)
    ec=$?
    if [[ -n "$out" ]]; then
        while IFS= read -r line; do
            log "sync: $line"
        done <<<"$out"
    fi
    return "$ec"
}

# --- main ---
if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Run as root (N-sight agent / sudo)"
    log "Not root" "ERROR"
    exit $EXIT_CRITICAL
fi

AGENT_BIN=$(find_agent_binary || true)
if [[ -z "$AGENT_BIN" ]]; then
    echo "CRITICAL: rmmagentd not found — N-sight Mac agent missing or broken install"
    log "Binary not found in ${AGENT_BINARY_PATHS[*]}" "ERROR"
    exit $EXIT_CRITICAL
fi

log "Binary: $AGENT_BIN"

if is_agent_running; then
    AGENT_PID=$(pgrep -x rmmagentd | head -1)
    log "Agent already running PID=$AGENT_PID"
    if [[ "$RUN_SYNC" == "1" ]]; then
        if try_sync "$AGENT_BIN"; then
            SYNC_OK=true
        else
            SYNC_OK=false
            log "sync failed while agent was up" "WARN"
        fi
    fi
    if [[ "$SYNC_OK" == true ]]; then
        echo "OK: N-sight Mac agent healthy | rmmagentd PID ${AGENT_PID} | $(hostname -s 2>/dev/null || hostname)"
        exit $EXIT_SUCCESS
    fi
    echo "WARNING: rmmagentd running but dashboard sync failed | $(hostname -s 2>/dev/null || hostname)"
    exit $EXIT_WARNING
fi

# Process not running
log "rmmagentd not running" "WARN"

if [[ "$SELF_HEAL" != "1" ]]; then
    echo "CRITICAL: rmmagentd not running (self-heal disabled NSIGHT_AGENT_SELF_HEAL=0)"
    exit $EXIT_CRITICAL
fi

if recycle_agent_launchdaemon "$AGENT_BIN"; then
    :
else
    echo "CRITICAL: rmmagentd still not running after LaunchDaemon recycle | $(hostname -s 2>/dev/null || hostname)"
    log "Heal failed" "ERROR"
    exit $EXIT_CRITICAL
fi

AGENT_PID=$(pgrep -x rmmagentd | head -1)
log "Heal succeeded PID=$AGENT_PID"

if [[ "$RUN_SYNC" == "1" ]]; then
    if try_sync "$AGENT_BIN"; then
        SYNC_OK=true
    else
        SYNC_OK=false
    fi
fi

if [[ "$SYNC_OK" == true ]]; then
    echo "OK: N-sight Mac agent recovered | rmmagentd PID ${AGENT_PID} | $(hostname -s 2>/dev/null || hostname)"
    exit $EXIT_SUCCESS
fi

echo "WARNING: Agent restarted after heal but sync failed | PID ${AGENT_PID} | $(hostname -s 2>/dev/null || hostname)"
exit $EXIT_WARNING
