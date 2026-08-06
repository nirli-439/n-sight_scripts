#!/usr/bin/env bash
# =============================================================================
# Reinstall_MSP_Anywhere_mac.sh - Reinstall MSP Anywhere Agent (Self-Relocating)
# =============================================================================
#
# SYNOPSIS:
#     Reinstalls the N-Sight MSP Anywhere agent on macOS WITHOUT breaking
#     the current remote terminal/SSH session. Self-copies to /tmp first.
#
# DESCRIPTION:
#     Self-relocating reinstall workflow:
#     1. If not already in /tmp: validates, copies self to /tmp, re-executes via nohup
#     2. Parent exits immediately - remote session stays alive
#     3. /tmp copy runs independently (survives network disconnect):
#        - Stops and unloads the MSP Anywhere LaunchDaemon
#        - Removes the app bundle from /Applications
#        - Cleans up LaunchDaemon plist and related files
#        - Downloads the Remote Worker (RW) package from N-Sight
#        - Installs the new agent
#        - Starts the service and verifies it's running
#
#     WHY SELF-RELOCATE: If you're connected via TakeControl/remote terminal,
#     the script needs to survive:
#       - Network disconnects
#       - SSH session drops  
#       - TakeControl disconnects during MSP Anywhere restart
#     By copying to /tmp and using nohup, the script runs entirely from
#     local disk and survives all of these.
#
#     WARNING: Reinstalling will require re-approving TCC permissions
#     (Screen Recording, Accessibility, Full Disk Access) on first connect.
#
# EXIT CODES:
#     0    = Success (reinstall initiated, running from /tmp)
#     1001 = Warning
#     1002 = Critical/Error (validation failed before relocation)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Reinstall_MSP_Anywhere_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Reinstall_MSP_Anywhere_mac.sh" | sudo bash
#
#     Monitor progress:   tail -f /var/log/nsight/ReinstallMSPAnywhere_*.log
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Root privileges (sudo), internet connection for download
#     Platform: macOS 10.15+ (Catalina and later)
#
#     N-Sight Monitoring:
#     - Process Check: MSP Anywhere Agent
#     - OSX Daemon Check: com.nable.mspanywhere.agent
#     - LaunchDaemon Path: /Library/LaunchDaemons/com.nable.mspanywhere.agent.plist
#
# =============================================================================

set -o pipefail

# =============================================================================
# SELF-RELOCATION: Copy to /tmp and re-execute if not already there
# =============================================================================

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_NAME_ONLY="$(basename "$SCRIPT_SOURCE")"
TMP_SCRIPT="/tmp/${SCRIPT_NAME_ONLY}_$$.sh"
LOG_DIR="/var/log/nsight"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="${LOG_DIR}/ReinstallMSPAnywhere_$(date +%Y%m%d_%H%M%S).log"

# Check if we're already running from /tmp
if [[ "$SCRIPT_SOURCE" != /tmp/* ]]; then
    echo "[INFO] =========================================="
    echo "[INFO] MSP Anywhere Reinstall - Self-Relocation"
    echo "[INFO] =========================================="
    echo "[INFO] Current location: $SCRIPT_SOURCE"
    echo "[INFO] Will copy to: $TMP_SCRIPT"
    echo "[INFO]"

    # Validate root before copying
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] This script requires root privileges (sudo)"
        exit 1002
    fi

    # Validate URL is set before copying/relaunching
    if [[ -z "${MSPANYWHERE_RW_URL:-}" ]]; then
        echo ""
        echo "[ERROR] MSPANYWHERE_RW_URL environment variable not set"
        echo "[INFO] Set it with your N-Sight RW package URL, then re-run:"
        echo "  export MSPANYWHERE_RW_URL='https://dashboard.systemmonitor.us/download/...'"
        exit 1002
    fi

    # Copy script to /tmp
    if ! cp "$SCRIPT_SOURCE" "$TMP_SCRIPT" 2>/dev/null; then
        echo "[ERROR] Failed to copy script to /tmp"
        exit 1002
    fi

    chmod +x "$TMP_SCRIPT" 2>/dev/null

    # Export the URL so the /tmp copy inherits it
    export MSPANYWHERE_RW_URL

    echo "[INFO] Script copied to /tmp successfully"
    echo "[INFO] Relaunching from /tmp with nohup (survives disconnect)..."
    echo "[INFO]"
    echo "[INFO] >>> This session will return immediately."
    echo "[INFO] >>> The reinstall continues in background even if you disconnect."
    echo "[INFO] >>> Monitor with: tail -f ${LOG_FILE}"
    echo ""

    # Re-execute from /tmp using nohup - survives hangup (SSH disconnect, etc)
    # Stdout/stderr redirected to /dev/null so this session isn't blocked
    nohup bash "$TMP_SCRIPT" </dev/null >/dev/null 2>&1 &
    NOHUP_PID=$!

    # Give it a moment to start
    sleep 2

    # Verify the process started
    if kill -0 "$NOHUP_PID" 2>/dev/null; then
        echo "OK: MSP Anywhere reinstall running in background (PID: $NOHUP_PID)"
        echo "    Location: $TMP_SCRIPT"
        echo "    Log: $LOG_FILE"
        echo ""
        echo "The script is now running from /tmp and will survive:"
        echo "  - Network disconnects"
        echo "  - SSH session drops"
        echo "  - TakeControl disconnects"
        echo ""
        echo "After ~60-90 seconds, reconnect via N-Sight dashboard."
        echo "First connection will require re-approving TCC permissions."
        exit 0
    else
        echo "WARNING: Background process may not have started properly"
        echo "Check: $LOG_FILE"
        exit 1001
    fi
fi

# =============================================================================
# MAIN EXECUTION: Running from /tmp (survives disconnect)
# =============================================================================

# All output goes to log file
exec &>> "$LOG_FILE"

echo "=========================================="
echo "MSP Anywhere Reinstall - Running from /tmp"
echo "=========================================="
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hostname: $(hostname)"
echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
echo "Script: $SCRIPT_SOURCE"
echo "PID: $$"
echo "PPID: $PPID"
echo "Log: $LOG_FILE"
echo ""

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Reinstall MSP Anywhere Agent"
readonly SCRIPT_VERSION="1.1"

# Exit codes for N-Sight
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Known app bundle paths to remove
readonly APP_BUNDLE_PATHS=(
    "/Applications/MSP Anywhere Agent.app"
    "/Applications/MSP Anywhere Agent (Advanced).app"
)

# Known LaunchDaemon identifiers
readonly LAUNCHDAEMON_LABELS=(
    "com.nable.mspanywhere.agent"
    "com.nable.mspanywhere"
    "com.mspanywhere.agent"
)

# Process patterns
readonly PROCESS_PATTERNS=(
    "MSP Anywhere"
    "TakeControl"
    "mspa"
)

# Package config
RW_PACKAGE_URL="${MSPANYWHERE_RW_URL:-}"
DOWNLOAD_PATH="/tmp/MSPAnywhere_RW_$(date +%Y%m%d_%H%M%S).pkg"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1"
}

cleanup() {
    log "Cleaning up temporary files..."
    [[ -f "$DOWNLOAD_PATH" ]] && rm -f "$DOWNLOAD_PATH" 2>/dev/null
    # Clean up this script copy from /tmp
    [[ "$SCRIPT_SOURCE" == /tmp/* ]] && rm -f "$SCRIPT_SOURCE" 2>/dev/null
}

trap cleanup EXIT

find_existing_bundle() {
    local path
    for path in "${APP_BUNDLE_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

find_launchdaemon_plist() {
    local label
    for label in "${LAUNCHDAEMON_LABELS[@]}"; do
        local plist="/Library/LaunchDaemons/${label}.plist"
        if [[ -f "$plist" ]]; then
            echo "$plist"
            return 0
        fi
    done

    local f
    for f in /Library/LaunchDaemons/*.plist; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *mspa*|*mspanywhere*|*takecontrol*|*nable*)
                echo "$f"
                return 0
                ;;
        esac
    done
    return 1
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
        pids="${pids}${found} "
    done
    echo "$pids" | tr -s ' ' | sed 's/^ //;s/ $//'
}

# =============================================================================
# TCC PERMISSION FUNCTIONS (Screen Recording, Accessibility, Full Disk Access)
# =============================================================================

get_msp_bundle_id() {
    # Try to get bundle ID from installed app
    local bundle
    bundle=$(find_existing_bundle)
    if [[ -n "$bundle" ]]; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${bundle}/Contents/Info.plist" 2>/dev/null
    else
        # Default known bundle IDs for MSP Anywhere
        echo "com.nable.mspanywhere.agent"
    fi
}

check_screen_recording_permission() {
    # Check if MSP Anywhere has Screen Recording permission
    local bundle_id
    bundle_id=$(get_msp_bundle_id)

    # Query TCC database for Screen Recording (kTCCServiceScreenCapture)
    local result
    result=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "SELECT client, auth_value FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%msp%'" 2>/dev/null)

    if [[ -n "$result" ]]; then
        # auth_value: 0=denied, 1=unknown, 2=allowed, 3=limited
        if echo "$result" | grep -q "|2$"; then
            echo "GRANTED"
        elif echo "$result" | grep -q "|0$"; then
            echo "DENIED"
        else
            echo "UNKNOWN"
        fi
    else
        echo "NOT_SET"
    fi
}

check_accessibility_permission() {
    # Check if MSP Anywhere has Accessibility permission
    local bundle_id
    bundle_id=$(get_msp_bundle_id)

    # Query TCC database for Accessibility (kTCCServiceAccessibility)
    local result
    result=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "SELECT client, auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%msp%'" 2>/dev/null)

    if [[ -n "$result" ]]; then
        if echo "$result" | grep -q "|2$"; then
            echo "GRANTED"
        elif echo "$result" | grep -q "|0$"; then
            echo "DENIED"
        else
            echo "UNKNOWN"
        fi
    else
        echo "NOT_SET"
    fi
}

check_full_disk_access_permission() {
    # Check if MSP Anywhere has Full Disk Access permission
    local bundle_id
    bundle_id=$(get_msp_bundle_id)

    # Query TCC database for Full Disk Access (kTCCServiceSystemPolicyAllFiles)
    local result
    result=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "SELECT client, auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client LIKE '%msp%'" 2>/dev/null)

    if [[ -n "$result" ]]; then
        if echo "$result" | grep -q "|2$"; then
            echo "GRANTED"
        elif echo "$result" | grep -q "|0$"; then
            echo "DENIED"
        else
            echo "UNKNOWN"
        fi
    else
        echo "NOT_SET"
    fi
}

log_tcc_status() {
    log "Checking TCC (privacy) permissions..."

    local screen_rec
    local accessibility
    local full_disk

    screen_rec=$(check_screen_recording_permission)
    accessibility=$(check_accessibility_permission)
    full_disk=$(check_full_disk_access_permission)

    log "Screen Recording:    $screen_rec"
    log "Accessibility:       $accessibility"
    log "Full Disk Access:    $full_disk"

    # Warn if any are not granted
    if [[ "$screen_rec" != "GRANTED" ]] || [[ "$accessibility" != "GRANTED" ]] || [[ "$full_disk" != "GRANTED" ]]; then
        log ""
        log "WARNING: Some TCC permissions are not granted" "WARNING"
        log "These must be approved manually in System Settings on first connect:"
        log "  1. System Settings > Privacy & Security > Screen Recording"
        log "  2. System Settings > Privacy & Security > Accessibility"
        log "  3. System Settings > Privacy & Security > Full Disk Access"
        log ""
        log "Or use MDM/Configuration Profile to pre-approve (recommended for fleet)"
    else
        log "All TCC permissions are granted ✓" "SUCCESS"
    fi
}

# =============================================================================
# MDM/CONFIGURATION PROFILE PRE-APPROVAL (Optional)
# =============================================================================

create_tcc_config_profile() {
    # Creates a mobileconfig file that can be deployed via MDM to pre-approve TCC
    local profile_path="/tmp/MSPAnywhere_TCC_Profile_$(date +%Y%m%d).mobileconfig"
    local bundle_id
    bundle_id=$(get_msp_bundle_id)

    cat > "$profile_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadIdentifier</key>
            <string>com.yourorg.tcc.profile.mspanywhere</string>
            <key>PayloadType</key>
            <string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadUUID</key>
            <string>$(uuidgen)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Services</key>
            <dict>
                <key>Accessibility</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier \"$bundle_id\" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>ScreenCapture</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier \"$bundle_id\" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>SystemPolicyAllFiles</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier \"$bundle_id\" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Pre-approves MSP Anywhere TCC permissions for remote access</string>
    <key>PayloadDisplayName</key>
    <string>MSP Anywhere TCC Permissions</string>
    <key>PayloadIdentifier</key>
    <string>com.yourorg.mspanywhere.tcc</string>
    <key>PayloadOrganization</key>
    <string>Your Organization</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>$(uuidgen)</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

    log "TCC Configuration Profile created: $profile_path"
    log "Deploy this via MDM (Jamf, Kandji, Mosyle, etc.) to pre-approve permissions"
}

stop_and_unload_agent() {
    log "Stopping MSP Anywhere agent..."

    local pids
    pids=$(get_running_pids)
    if [[ -n "$pids" ]]; then
        log "Found PIDs: $pids"
        local pattern
        for pattern in "${PROCESS_PATTERNS[@]}"; do
            pkill -TERM -f "$pattern" 2>/dev/null || true
        done
        sleep 2
        for pattern in "${PROCESS_PATTERNS[@]}"; do
            pkill -KILL -f "$pattern" 2>/dev/null || true
        done
    else
        log "No running processes found"
    fi

    local plist
    plist=$(find_launchdaemon_plist)
    if [[ -n "$plist" ]]; then
        local label
        label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null)
        if [[ -n "$label" ]]; then
            log "Unloading LaunchDaemon: $label"
            launchctl unload "$plist" 2>/dev/null || true
            launchctl remove "$label" 2>/dev/null || true
        fi
    fi

    log "Agent stopped"
}

remove_existing_installation() {
    log "Removing existing installation..."

    local removed=false
    local path
    for path in "${APP_BUNDLE_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            log "Removing: $path"
            rm -rf "$path" 2>/dev/null
            [[ ! -d "$path" ]] && removed=true
        fi
    done

    local plist
    plist=$(find_launchdaemon_plist)
    if [[ -n "$plist" && -f "$plist" ]]; then
        log "Removing plist: $plist"
        rm -f "$plist" 2>/dev/null
        removed=true
    fi

    for label in "${LAUNCHDAEMON_LABELS[@]}"; do
        local known_plist="/Library/LaunchDaemons/${label}.plist"
        if [[ -f "$known_plist" ]]; then
            log "Removing: $known_plist"
            rm -f "$known_plist" 2>/dev/null
            removed=true
        fi
    done

    rm -rf "/Library/Logs/MSP Anywhere Agent TakeControl" 2>/dev/null || true
    rm -rf "/Library/Application Support/MSP Anywhere" 2>/dev/null || true

    [[ "$removed" = true ]] && log "Existing installation removed" "SUCCESS" || log "No existing installation found"
}

download_rw_package() {
    log "Downloading Remote Worker package..."

    if [[ -z "$RW_PACKAGE_URL" ]]; then
        log "RW_PACKAGE_URL not set" "ERROR"
        return 1
    fi

    log "URL: $RW_PACKAGE_URL"

    if ! curl -L --retry 3 --retry-delay 5 -o "$DOWNLOAD_PATH" "$RW_PACKAGE_URL" 2>/dev/null; then
        log "Download failed" "ERROR"
        return 1
    fi

    if [[ ! -f "$DOWNLOAD_PATH" ]]; then
        log "Download file missing" "ERROR"
        return 1
    fi

    local file_size
    file_size=$(stat -f%z "$DOWNLOAD_PATH" 2>/dev/null || stat -c%s "$DOWNLOAD_PATH" 2>/dev/null || echo "0")
    if [[ "$file_size" -lt 1000000 ]]; then
        log "Downloaded file too small (${file_size} bytes)" "ERROR"
        return 1
    fi

    log "Downloaded: ${file_size} bytes" "SUCCESS"
    return 0
}

install_package() {
    log "Installing package..."

    if [[ ! -f "$DOWNLOAD_PATH" ]]; then
        log "Package not found" "ERROR"
        return 1
    fi

    if ! installer -pkg "$DOWNLOAD_PATH" -target / 2>&1; then
        log "Installation failed" "ERROR"
        return 1
    fi

    log "Installation complete" "SUCCESS"
    return 0
}

start_agent() {
    log "Starting agent..."
    sleep 3

    local plist
    plist=$(find_launchdaemon_plist)

    if [[ -n "$plist" && -f "$plist" ]]; then
        log "Loading LaunchDaemon: $plist"
        launchctl load "$plist" 2>/dev/null || true
        sleep 5
    fi

    if is_agent_running; then
        log "Agent is running" "SUCCESS"
        return 0
    fi

    local bundle
    bundle=$(find_existing_bundle)
    if [[ -n "$bundle" ]]; then
        local executable
        executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${bundle}/Contents/Info.plist" 2>/dev/null)
        if [[ -n "$executable" ]]; then
            local exe_path="${bundle}/Contents/MacOS/${executable}"
            if [[ -x "$exe_path" ]]; then
                log "Launching: $exe_path"
                nohup "$exe_path" &>/dev/null &
                sleep 5
            fi
        fi
    fi

    if is_agent_running; then
        log "Agent is running after direct launch" "SUCCESS"
        return 0
    fi

    return 1
}

# =============================================================================
# MAIN WORKFLOW
# =============================================================================

log "=========================================="
log "Starting Reinstall"
log "=========================================="

# Step 1: Check existing
EXISTING_BUNDLE=$(find_existing_bundle)
[[ -n "$EXISTING_BUNDLE" ]] && log "Found existing: $EXISTING_BUNDLE" || log "No existing installation"

# Step 2: Stop and remove
log ""
stop_and_unload_agent
remove_existing_installation

# Step 3: Download
log ""
if ! download_rw_package; then
    log "Reinstall failed at download step" "ERROR"
    exit 1
fi

# Step 4: Install
log ""
if ! install_package; then
    log "Reinstall failed at install step" "ERROR"
    exit 1
fi

# Step 5: Start
log ""
if ! start_agent; then
    log "Agent may not be running - check manually" "WARNING"
fi

# Step 6: Check TCC Permissions
log ""
log_tcc_status

# Optional: Create MDM profile for fleet pre-approval
if [[ "${CREATE_TCC_PROFILE:-}" = "yes" ]]; then
    log ""
    create_tcc_config_profile
fi

# Summary
log ""
log "=========================================="
log "Reinstall Summary"
log "=========================================="

sleep 3

FINAL_RUNNING=false
if is_agent_running; then
    FINAL_RUNNING=true
fi

NEW_BUNDLE=$(find_existing_bundle)

log "Old: ${EXISTING_BUNDLE:-None}"
log "New: ${NEW_BUNDLE:-Not found}"
log "Running: $([ "$FINAL_RUNNING" = true ] && echo "Yes (PIDs: $(get_running_pids))" || echo "No")"

if [[ "$FINAL_RUNNING" = true ]]; then
    log "Reinstall SUCCESS - Agent is running" "SUCCESS"
    log ""
    log "NEXT STEPS FOR REMOTE ACCESS:"
    log "=============================="
    log "1. Connect via N-Sight dashboard (allow 30-60s for agent to register)"
    log "2. On first connect, macOS will prompt for permissions - approve ALL:"
    log "   ✓ Screen Recording"
    log "   ✓ Accessibility"
    log "   ✓ Full Disk Access"
    log ""
    log "For MDM-managed devices: Deploy TCC config profile to auto-approve"
    log "Set CREATE_TCC_PROFILE=yes to generate the mobileconfig file"
    log ""
elif [[ -n "$NEW_BUNDLE" ]]; then
    log "Installed but not confirmed running" "WARNING"
else
    log "Installation failed" "ERROR"
fi

log "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
log "Log file: $LOG_FILE"

# Cleanup happens via trap EXIT
exit 0
