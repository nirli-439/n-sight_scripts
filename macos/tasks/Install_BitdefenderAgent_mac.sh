#!/bin/bash
# =============================================================================
# Install_BitdefenderAgent_mac.sh - Silent install of Bitdefender GravityZone (BEST) for macOS
# =============================================================================
#
# SYNOPSIS:
#     Downloads the organization's GravityZone setup_downloader.dmg, mounts it,
#     and runs SetupDownloader --silent (unattended, no UI). Unmounts and cleans up.
#
# DESCRIPTION:
#     - Skips if Bitdefender Endpoint Security Tools is already installed (idempotent)
#     - Downloads the DMG (company package, contains installer.xml with the GZ token)
#     - Mounts with -nobrowse (hidden from the user), finds SetupDownloader dynamically
#     - Runs: SetupDownloader.app/Contents/MacOS/SetupDownloader --silent
#     - Waits for the agent daemon to appear, then reports status
#
#     Vendor reference (silent flag / DMG layout):
#       https://bitdefender.com/business/support/en/77211-199818--runsetupdownloader.html
#       https://help.scalefusion.com/docs/configuring-bitdefender-on-macos-with-scalefusion
#
#     Pre-requisite for a fully silent experience (deploy via MDM BEFORE this script):
#       - System Extension allow:  Team ID GUNFMW623Y
#       - Network Extension:       com.bitdefender.cst.net.dci.dci-network-extension
#       - PPPC Full Disk Access:   com.bitdefender.epsecurity.BDLDaemonApp,
#                                  com.bitdefender.EndpointSecurityforMac,
#                                  /Library/Bitdefender/AVP/BDLDaemon
#       Without these the agent installs but the user sees approval prompts.
#
# EXIT CODES:
#     0    = Success (installed now, or already installed)
#     1001 = Warning (installer returned OK but agent not detected yet)
#     1002 = Critical (download / mount / installer failure)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Install_BitdefenderAgent_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Install_BitdefenderAgent_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.3
#     Requires: Root privileges
#     Platform: macOS 11+ (Intel & Apple Silicon)
#     Timeout: set the N-Sight task timeout to 1200s (SetupDownloader pulls the full kit)
#
# CHANGELOG:
#     1.3 - Mount at default /Volumes path + run from DMG root; "installed" now requires running daemon (no false OK)
#     1.2 - Drop hdiutil imageinfo gate (false CRITICAL on 33 MB GZ DMG); log hdiutil errors; auto-accept SLA
#     1.1 - Status line is now the first line of output (dashboard)
#     1.0 - Initial version
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="Install_BitdefenderAgent_mac"
readonly SCRIPT_VERSION="1.3"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Organization package (GravityZone > Network > Packages > macOS download link)
readonly DMG_URL="https://cloudgz.gravityzone.bitdefender.com/Packages/MAC/0/jWevAZ/setup_downloader.dmg"

readonly WORK_DIR="$(mktemp -d /tmp/bdgz.XXXXXX)"
readonly DMG_PATH="${WORK_DIR}/setup_downloader.dmg"
MOUNT_POINT=""   # set from hdiutil output (default /Volumes/<name>, like the vendor docs)

readonly INSTALLER_TIMEOUT=1080   # seconds to wait for SetupDownloader
readonly VERIFY_TIMEOUT=120       # seconds to wait for agent after installer exits

# Paths that indicate the agent is installed
readonly BD_DAEMON="/Library/Bitdefender/AVP/BDLDaemon"
readonly BD_APP="/Applications/Endpoint Security for Mac.app"

# =============================================================================
# FUNCTIONS
# =============================================================================
log() {
    local level="${2:-INFO}"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"
    echo "$line" >> "$LOG_FILE" 2>/dev/null   # file only - stdout line 1 is the status (finish)
}

cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1
    fi
    rm -rf "$WORK_DIR" 2>/dev/null
}
trap cleanup EXIT

finish() {
    # $1 = exit code, $2 = status line (printed first for the dashboard)
    echo "$2"
    log "$2" "RESULT"
    echo "Log: $LOG_FILE"
    tail -n 15 "$LOG_FILE" 2>/dev/null
    exit "$1"
}

# Installed = Bitdefender files present AND its daemon loaded/running (leftover folders don't count)
is_installed() {
    [[ -e "$BD_DAEMON" || -d "$BD_APP" ]] || return 1
    pgrep -qf "BDLDaemon" && return 0
    launchctl list 2>/dev/null | grep -qi "bitdefender" && return 0
    return 1
}

leftovers() {
    local f=""
    [[ -e /Library/Bitdefender ]] && f+="/Library/Bitdefender "
    [[ -d "$BD_APP" ]] && f+="'$BD_APP' "
    f+="$(ls /Library/LaunchDaemons/com.bitdefender.* 2>/dev/null | tr '\n' ' ')"
    f+="$(pkgutil --pkgs 2>/dev/null | grep -i bitdefender | tr '\n' ' ')"
    echo "${f:-none}"
}

agent_version() {
    local v=""
    [[ -d "$BD_APP" ]] && v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BD_APP/Contents/Info.plist" 2>/dev/null)
    echo "${v:-unknown}"
}

# =============================================================================
# MAIN
# =============================================================================
mkdir -p "$LOG_DIR" 2>/dev/null

if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Root privileges required"
    exit $EXIT_CRITICAL
fi

log "$SCRIPT_NAME v$SCRIPT_VERSION on $(hostname) - macOS $(sw_vers -productVersion) ($(uname -m))"

# 1. Idempotency
log "Pre-check leftovers: $(leftovers)"
if is_installed; then
    finish $EXIT_SUCCESS "OK: Bitdefender GravityZone agent already installed (v$(agent_version)) - nothing to do"
fi

# 2. Download
log "Downloading $DMG_URL"
if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 600 -o "$DMG_PATH" "$DMG_URL"; then
    finish $EXIT_CRITICAL "CRITICAL: Failed to download Bitdefender setup_downloader.dmg (check URL / network)"
fi
DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
log "Downloaded ${DMG_SIZE} bytes ($(file -b "$DMG_PATH" 2>/dev/null))"
# Only reject obvious non-DMGs (HTML error page / tiny file). Real validation = hdiutil attach.
# (v1.1 used 'hdiutil imageinfo', which fails on the GravityZone DMG under N-Sight - removed.)
if (( DMG_SIZE < 1048576 )) || head -c 1024 "$DMG_PATH" | grep -qiE '<html|<!doctype|accessdenied'; then
    finish $EXIT_CRITICAL "CRITICAL: Download is not a DMG (${DMG_SIZE} bytes) - check the GravityZone package URL"
fi

# 3. Mount (hidden from Finder)
xattr -c "$DMG_PATH" 2>/dev/null
# printf answers 'Y' to a licence agreement (SLA) if the DMG has one; full hdiutil output goes to the log
if ! attach_out=$(printf 'Y\n' | hdiutil attach "$DMG_PATH" -nobrowse -noautoopen 2>&1); then
    log "hdiutil attach output: $(echo "$attach_out" | tail -n 5 | tr '\n' ' ')" "ERROR"
    finish $EXIT_CRITICAL "CRITICAL: Failed to mount setup_downloader.dmg - $(echo "$attach_out" | tail -n 1 | cut -c1-150)"
fi
MOUNT_POINT=$(echo "$attach_out" | grep -o '/Volumes/.*' | tail -n 1)
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    log "hdiutil attach output: $(echo "$attach_out" | tr '\n' ' ')" "ERROR"
    finish $EXIT_CRITICAL "CRITICAL: DMG attached but mount point not found"
fi
log "Mounted at '$MOUNT_POINT'"
log "DMG contents: $(ls -1 "$MOUNT_POINT" 2>&1 | tr '\n' '|')"

# 4. Locate SetupDownloader (volume name varies: 'Endpoint for MAC', etc.)
SETUP_BIN=$(find "$MOUNT_POINT" -maxdepth 4 -type f -path "*SetupDownloader.app/Contents/MacOS/SetupDownloader" 2>/dev/null | head -1)
if [[ -z "$SETUP_BIN" ]]; then
    log "DMG contents: $(ls -la "$MOUNT_POINT" 2>&1 | tr '\n' ' ')" "ERROR"
    finish $EXIT_CRITICAL "CRITICAL: SetupDownloader not found inside the DMG"
fi
[[ -f "$MOUNT_POINT/installer.xml" ]] || log "installer.xml not found at DMG root - downloader may still embed config" "WARN"
log "Running: $SETUP_BIN --silent"

# 5. Run installer silently with a timeout
cd "$MOUNT_POINT" || finish $EXIT_CRITICAL "CRITICAL: cannot cd to '$MOUNT_POINT'"
"$SETUP_BIN" --silent >> "$LOG_FILE" 2>&1 &
pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= INSTALLER_TIMEOUT )); then
        kill -9 "$pid" 2>/dev/null
        finish $EXIT_CRITICAL "CRITICAL: SetupDownloader timed out after ${INSTALLER_TIMEOUT}s"
    fi
    sleep 5; (( elapsed += 5 ))
done
wait "$pid"; rc=$?
log "SetupDownloader exited with code $rc after ${elapsed}s"
cd / 2>/dev/null
(( elapsed < 30 )) && log "SetupDownloader finished in <30s - it probably did not download/install the kit" "WARN"

if (( rc != 0 )); then
    finish $EXIT_CRITICAL "CRITICAL: Bitdefender SetupDownloader failed (exit $rc) - check network access to GravityZone and the log"
fi

# 6. Verify
waited=0
until is_installed || (( waited >= VERIFY_TIMEOUT )); do
    sleep 5; (( waited += 5 ))
done

if is_installed; then
    finish $EXIT_SUCCESS "OK: Bitdefender GravityZone agent installed (v$(agent_version)) in $((elapsed + waited))s"
else
    log "Post-check leftovers: $(leftovers)"
    finish $EXIT_WARNING "WARNING: SetupDownloader exit 0 after ${elapsed}s but Bitdefender daemon not running - see log"
fi
