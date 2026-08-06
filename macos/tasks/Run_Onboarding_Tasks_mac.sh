#!/usr/bin/env bash
# =============================================================================
# Run_Onboarding_Tasks_mac.sh - Master Onboarding Script for macOS
# =============================================================================
#
# SYNOPSIS:
#     Sequentially downloads and executes all essential macOS onboarding scripts
#     straight from the repository for a smooth, single-click setup.
#
# DESCRIPTION:
#     This is a master task script designed for N-Sight RMM.
#     It runs the following installers in order:
#     1. Google Chrome
#     2. Google Drive
#     3. Slack
#     4. DisplayLink Manager
#
#     If any individual script fails, this master script logs the warning but
#     continues executing the remaining scripts, ensuring maximum possible setup.
#     The final exit code will reflect whether all scripts succeeded (0) or if
#     there were any warnings/errors (1001/1002).
#
# EXIT CODES:
#     0    = Success (All tasks completed successfully or already installed)
#     1001 = Warning (One or more tasks issued a warning or failed)
#     1002 = Critical/Error (Master script execution failed entirely)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Run_Onboarding_Tasks_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Run_Onboarding_Tasks_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges (sudo)
#     Platform: macOS 10.15+ (Catalina and later)
#
# =============================================================================

# Strict mode
set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="macOS Master Onboarding"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/Onboarding_mac_$(date +%Y%m%d_%H%M%S).log"

# Define the tasks to run in order
# Format: "TaskName|RawGitHubURL"
readonly TASKS=(
    "Google Chrome|https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_Chrome_mac.sh"
    "Google Drive|https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_GoogleDrive_mac.sh"
    "Slack|https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_Slack_mac.sh"
    "DisplayLink|https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_DisplayLink_mac.sh"
)

# Exit codes for N-Sight
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

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

write_summary() {
    local status="$1"
    local message="$2"
    echo ""
    echo "${status}: ${message}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script requires root privileges (sudo)" "ERROR"
        write_summary "CRITICAL" "Root privileges required"
        exit $EXIT_CRITICAL
    fi
}

run_task() {
    local task_name="$1"
    local url="$2"
    
    log "---------------------------------------------------"
    log "Executing Task: $task_name"
    log "URL: $url"
    
    # Download and execute the script in memory
    # Capture the output and exit code
    
    log "Downloading and running script..."
    
    # Execute the curl command, Piping straight to bash
    # We don't want the sub-script's 'exit' command to kill the master script, 
    # so we run it in a subshell by piping to bash
    local output
    local exit_code
    
    # Run the script and capture both stdout and stderr
    output=$(curl -fsSL "$url" | bash 2>&1)
    exit_code=$?
    
    # Log the output (indented for readability)
    echo "$output" | while IFS= read -r line; do
        log "  | $line" "OUT"
    done
    
    log "Task '$task_name' finished with exit code: $exit_code"
    
    if [ $exit_code -eq 0 ]; then
        log "Task SUCCESS: $task_name" "SUCCESS"
        return 0
    elif [ $exit_code -eq 1001 ]; then
        log "Task WARNING: $task_name (Usually means already installed)" "WARNING"
        return 1
    else
        log "Task FAILED: $task_name (Exit code $exit_code)" "ERROR"
        return 2
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION Started"
log "=========================================="
log "Hostname: $(hostname)"
log "User: $(whoami)"
log "macOS Version: $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
log "Log File: $LOG_FILE"
log "=========================================="

check_root

overall_success=true
warning_encountered=false
error_encountered=false

successful_tasks=0
total_tasks=${#TASKS[@]}

for task_info in "${TASKS[@]}"; do
    # Split by pipe
    task_name="${task_info%%|*}"
    task_url="${task_info##*|}"
    
    run_task "$task_name" "$task_url"
    result=$?
    
    if [ $result -eq 0 ]; then
        ((successful_tasks++))
    elif [ $result -eq 1 ]; then
        # Warning (often means already installed, which is technically fine but we note it)
        warning_encountered=true
        ((successful_tasks++)) # Count as "handled/done"
    else
        # Error
        overall_success=false
        error_encountered=true
    fi
done

log "=========================================="
log "ONBOARDING SUMMARY"
log "=========================================="
log "Tasks Attempted: $total_tasks"
log "Tasks Successful/Skipped: $successful_tasks"

if [ "$overall_success" = true ] && [ "$warning_encountered" = false ]; then
    log "All onboarding tasks completed perfectly." "SUCCESS"
    write_summary "OK" "macOS Onboarding completed successfully ($successful_tasks/$total_tasks tasks)"
    exit $EXIT_SUCCESS
elif [ "$overall_success" = true ] && [ "$warning_encountered" = true ]; then
    log "All tasks executed, but some reported warnings (likely already installed)." "WARNING"
    write_summary "WARNING" "macOS Onboarding completed with warnings ($successful_tasks/$total_tasks tasks)"
    exit $EXIT_WARNING
else
    log "One or more onboarding tasks failed entirely." "ERROR"
    write_summary "CRITICAL" "macOS Onboarding failed on some tasks. Check logs."
    exit $EXIT_CRITICAL
fi
