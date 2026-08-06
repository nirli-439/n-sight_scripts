#!/usr/bin/env bash
# =============================================================================
# Restart_TakeControl_Agent_mac.sh - Restart MSP Anywhere / TakeControl Agent
# =============================================================================
#
# SYNOPSIS:
#     Restarts the N-Sight TakeControl (MSP Anywhere) agent process on macOS
#     WITHOUT reinstalling — preserving all existing macOS TCC permissions
#     (Screen Recording, Accessibility, Full Disk Access).
#
# DESCRIPTION:
#     Safe restart approach:
#     1. Locates the MSP Anywhere Agent app bundle and its main executable
#     2. Finds the associated LaunchDaemon plist (via name pattern + content search)
#     3. Kills any running TakeControl/MSP Anywhere processes
#     4. Restarts via launchctl unload → load (respects existing permissions)
#     5. Falls back to direct binary launch if no LaunchDaemon found
#     6. Verifies the process is running after restart
#
# WHY NOT REINSTALL:
#     On macOS 10.15+, reinstalling an app that holds Screen Recording or
#     Accessibility permissions may trigger TCC approval dialogs on-screen.
#     Without physical access, those dialogs cannot be approved and remote
#     access would be permanently lost. This script only restarts — it never
#     modifies the app bundle or TCC database.
#
# EXIT CODES:
#     0    = Success (TakeControl agent is running)
#     1001 = Warning (process restarted but verification inconclusive)
#     1002 = Critical/Error (app not found or failed to start)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Restart_TakeControl_Agent_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Restart_TakeControl_Agent_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
#     Key paths (Mac Agent 3.x.x and later):
#       App bundle:  /Applications/MSP Anywhere Agent.app
#       Agent logs:  /Library/Logs/MSP Anywhere Agent TakeControl
#       Script logs: /var/log/nsight/
#
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Restart TakeControl Agent"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/RestartTakeControl_$(date +%Y%m%d_%H%M%S).log"

# Exit codes for N-Sight (use >1000 for proper output display)
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Known app bundle paths (checked in order)
readonly APP_BUNDLE_PATHS=(
    "/Applications/MSP Anywhere Agent.app"
    "/Applications/MSP Anywhere Agent (Advanced).app"
)

# Process name patterns to match when killing existing instances
# Using -f (full command line match) to catch all variants
readonly PROCESS_PATTERNS=(
    "MSP Anywhere"
    "TakeControl"
    "mspa"
)

# Seconds to wait after stopping before starting, and after starting before verifying
readonly STOP_WAIT=3
readonly START_WAIT=8

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$level] $1"
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        echo ""
        echo "CRITICAL: Root privileges required"
        exit $EXIT_CRITICAL
    fi
}

find_app_bundle() {
    local path
    for path in "${APP_BUNDLE_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

get_bundle_executable() {
    # Extract the main executable name from the app's Info.plist
    local bundle="$1"
    local plist="${bundle}/Contents/Info.plist"
    local exe_name

    if [[ -f "$plist" ]]; then
        exe_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
        if [[ -n "$exe_name" ]]; then
            echo "${bundle}/Contents/MacOS/${exe_name}"
            return 0
        fi
    fi
    return 1
}

get_bundle_identifier() {
    local bundle="$1"
    local plist="${bundle}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null
}

find_launchdaemon_plist() {
    local bundle_id="$1"

    # Search by bundle identifier match inside plist content (most accurate)
    if [[ -n "$bundle_id" ]]; then
        local plist
        plist=$(grep -rl "$bundle_id" /Library/LaunchDaemons 2>/dev/null | head -1)
        if [[ -n "$plist" ]]; then
            echo "$plist"
            return 0
        fi
    fi

    # Search by filename pattern
    local f
    for f in /Library/LaunchDaemons/*.plist; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *mspa*|*mspanywhere*|*takecontrol*|*n-able*|*nable*)
                echo "$f"
                return 0
                ;;
        esac
    done

    # Fallback: search plist contents for known process keywords
    local plist
    plist=$(grep -ril "msp anywhere\|mspa\|takecontrol" /Library/LaunchDaemons 2>/dev/null | head -1)
    if [[ -n "$plist" ]]; then
        echo "$plist"
        return 0
    fi

    return 1
}

get_launchdaemon_label() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null
}

is_agent_running() {
    local pattern
    for pattern in "${PROCESS_PATTERNS[@]}"; do
        if pgrep -f "$pattern" > /dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

get_running_pids() {
    local pids=""
    local pattern
    for pattern in "${PROCESS_PATTERNS[@]}"; do
        local found
        found=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ')
        pids="${pids}${found}"
    done
    echo "$pids" | tr -s ' ' | sed 's/^ //;s/ $//'
}

stop_agent() {
    log "Stopping existing TakeControl processes..."

    local pids
    pids=$(get_running_pids)

    if [[ -z "$pids" ]]; then
        log "No running TakeControl processes found"
        return 0
    fi

    log "Found PIDs: $pids"

    # Graceful SIGTERM first
    local pattern
    for pattern in "${PROCESS_PATTERNS[@]}"; do
        pkill -TERM -f "$pattern" 2>/dev/null || true
    done

    sleep "$STOP_WAIT"

    # Force kill anything still running
    for pattern in "${PROCESS_PATTERNS[@]}"; do
        pkill -KILL -f "$pattern" 2>/dev/null || true
    done

    sleep 1
    log "Stop complete"
}

start_agent() {
    local plist="$1"
    local executable="$2"

    # Preferred: restart via launchctl (preserves all system context and permissions)
    if [[ -n "$plist" ]]; then
        local label
        label=$(get_launchdaemon_label "$plist")
        log "Restarting via launchctl (label: ${label:-unknown})..."

        launchctl unload "$plist" 2>/dev/null || true
        sleep 1
        launchctl load "$plist" 2>/dev/null
        sleep "$START_WAIT"

        if is_agent_running; then
            log "Agent started successfully via launchctl" "SUCCESS"
            return 0
        fi
        log "launchctl load did not start the agent — trying direct launch" "WARNING"
    fi

    # Fallback: launch the executable directly
    if [[ -n "$executable" && -x "$executable" ]]; then
        log "Launching directly: $executable"
        "$executable" &
        sleep "$START_WAIT"

        if is_agent_running; then
            log "Agent started successfully via direct launch" "SUCCESS"
            return 0
        fi
    fi

    log "Failed to start TakeControl agent" "ERROR"
    return 1
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

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

# ------------------------------------------------------------------
# Step 1: Find app bundle
# ------------------------------------------------------------------
log "Step 1: Locating MSP Anywhere Agent app bundle..."

APP_BUNDLE=$(find_app_bundle)
if [[ -z "$APP_BUNDLE" ]]; then
    log "MSP Anywhere Agent app bundle not found" "ERROR"
    log "Searched: ${APP_BUNDLE_PATHS[*]}" "ERROR"
    echo ""
    echo "CRITICAL: MSP Anywhere Agent is not installed — cannot restart"
    exit $EXIT_CRITICAL
fi

log "App bundle: $APP_BUNDLE"

BUNDLE_ID=$(get_bundle_identifier "$APP_BUNDLE")
log "Bundle ID: ${BUNDLE_ID:-unknown}"

EXECUTABLE=$(get_bundle_executable "$APP_BUNDLE")
log "Executable: ${EXECUTABLE:-unknown}"
log ""

# ------------------------------------------------------------------
# Step 2: Find LaunchDaemon plist
# ------------------------------------------------------------------
log "Step 2: Locating LaunchDaemon plist..."

PLIST=$(find_launchdaemon_plist "$BUNDLE_ID")
if [[ -n "$PLIST" ]]; then
    log "LaunchDaemon found: $PLIST"
else
    log "No LaunchDaemon plist found — will use direct launch fallback" "WARNING"
fi
log ""

# ------------------------------------------------------------------
# Step 3: Check current status
# ------------------------------------------------------------------
log "Step 3: Checking current agent status..."

if is_agent_running; then
    log "Agent is currently running (PIDs: $(get_running_pids))"
    AGENT_WAS_RUNNING=true
else
    log "Agent is NOT currently running" "WARNING"
    AGENT_WAS_RUNNING=false
fi
log ""

# ------------------------------------------------------------------
# Step 4: Stop existing processes
# ------------------------------------------------------------------
log "Step 4: Stopping agent..."
stop_agent
log ""

# ------------------------------------------------------------------
# Step 5: Start agent
# ------------------------------------------------------------------
log "Step 5: Starting agent..."
START_OK=false
if start_agent "$PLIST" "$EXECUTABLE"; then
    START_OK=true
fi
log ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
log "=========================================="
log "Restart Summary"
log "=========================================="

FINAL_RUNNING=false
if is_agent_running; then
    FINAL_RUNNING=true
fi

echo ""
echo "=========================================="
echo "TakeControl Agent Restart Results"
echo "=========================================="
echo "Hostname:   $(hostname)"
echo "App:        $APP_BUNDLE"
echo "Bundle ID:  ${BUNDLE_ID:-unknown}"
echo "LaunchDaemon: ${PLIST:-not found}"
echo ""
echo "Was running before: $([ "$AGENT_WAS_RUNNING" = true ] && echo "Yes" || echo "No")"
echo "Running after:      $([ "$FINAL_RUNNING" = true ] && echo "Yes (PIDs: $(get_running_pids))" || echo "No")"
echo ""

if [ "$FINAL_RUNNING" = true ]; then
    log "TakeControl agent is running after restart" "SUCCESS"
    echo "OK: TakeControl agent restarted successfully"
    echo "Note: Allow 30-60 seconds for the agent to establish connection to N-Sight"
    exit $EXIT_SUCCESS
elif [ "$START_OK" = true ]; then
    log "Start command succeeded but process not confirmed running" "WARNING"
    echo "WARNING: Agent may still be initialising — check again in 60 seconds"
    exit $EXIT_WARNING
else
    log "TakeControl agent failed to start" "ERROR"
    echo "CRITICAL: TakeControl agent could not be restarted"
    echo "Check log: $LOG_FILE"
    echo "Check agent logs: /Library/Logs/MSP Anywhere Agent TakeControl/"
    exit $EXIT_CRITICAL
fi
