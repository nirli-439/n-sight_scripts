#!/bin/bash
# =============================================================================
# Install_NSight_Agent_mac.sh - Silent install of the N-able N-Sight Mac agent
# =============================================================================
#
# SYNOPSIS:
#     Downloads the Remote Worker site package (install.pkg + settings.ini),
#     installs it, and verifies rmmagentd is running. Idempotent.
#
# DESCRIPTION:
#     - Skips if the agent is already installed and running
#     - Downloads the site package from PKG_URL (N-Sight dashboard >
#       Agent > Download Agent > Site Installation Package / Add devices)
#     - Dashboard download links EXPIRE. If the download fails, copy a fresh
#       link and either update PKG_URL below or run with:
#         sudo NSIGHT_PKG_URL='https://...' bash Install_NSight_Agent_mac.sh
#     - Uses the settings.ini bundled in the package; falls back to the
#       Israel / Helfy Office site ini (SITEID=690373) if the package has none
#
# EXIT CODES:
#     0    = Success (installed now, or already installed)
#     1001 = Warning (installer ran but agent not detected yet)
#     1002 = Critical (download / install failure)
#
# EXECUTION:
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tasks/Install_NSight_Agent_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges
#     Replaces: Scalefusion_PreInstall_NSight_Israel.sh (ini now written here)
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Install_NSight_Agent_mac"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Dashboard download link for the Israel/Helfy RW package. EXPIRES - see header.
PKG_URL="${NSIGHT_PKG_URL:-https://wwweurope1.systemmonitor.eu.com/8fd01afc-a9c1-4dc3-b373-85c866497e3f}"
readonly PKG_URL

readonly WORK_DIR="$(mktemp -d /tmp/nsight.XXXXXX)"
readonly AGENT_BIN="/usr/local/rmmagent/rmmagentd"
readonly VERIFY_TIMEOUT=120

cleanup() { rm -rf "$WORK_DIR" 2>/dev/null; }
trap cleanup EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null; }

finish() {
    echo "$2"
    log "$2"
    tail -n 15 "$LOG_FILE" 2>/dev/null
    exit "$1"
}

is_installed() {
    [[ -x "$AGENT_BIN" || -x /usr/local/bin/rmmagentd ]] && pgrep -x rmmagentd >/dev/null
}

# Israel / Helfy Office site registration (was Scalefusion_PreInstall_NSight_Israel.sh)
write_settings_ini() {
    cat > /tmp/settings.ini << 'EOF'
[GENERAL]
SERVER1=https://upload1europe1.systemmonitor.eu.com/
SERVER2=https://upload2europe1.systemmonitor.eu.com/
SERVER3=https://upload3europe1.systemmonitor.eu.com/
SERVER4=https://upload4europe1.systemmonitor.eu.com/
USERNAME=nir.l@helfy.co
USERKEY=clmmbbbgiennencienhgdoeamfccnahhjfjedpjdilmpjemaoofcckmlolmenalgfhajbhnhgejbndddcfpcnceffmjpkhnkdgebgabkeiagnbdmdknkceenglennlpk
AGENTMODE=1
[AUTOINSTALL]
ON=1
SITEID=690373
[DEBUG]
VERBOSE=1
EOF
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

if is_installed; then
    finish $EXIT_SUCCESS "OK: N-Sight agent already installed and running (PID $(pgrep -x rmmagentd | head -1)) - nothing to do"
fi

# 1. Download the site package
log "Downloading $PKG_URL"
if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 600 -A "Mozilla/5.0" -o "$WORK_DIR/pkg.bin" "$PKG_URL"; then
    finish $EXIT_CRITICAL "CRITICAL: Failed to download agent package - link expired? Copy a fresh one from the dashboard and set NSIGHT_PKG_URL"
fi
log "Downloaded $(stat -f%z "$WORK_DIR/pkg.bin") bytes ($(file -b "$WORK_DIR/pkg.bin"))"

# 2. Unpack to find install.pkg (package may be ZIP, PKG or DMG)
case "$(file -b "$WORK_DIR/pkg.bin")" in
    Zip*)   unzip -qo "$WORK_DIR/pkg.bin" -d "$WORK_DIR/x" || finish $EXIT_CRITICAL "CRITICAL: failed to unzip agent package" ;;
    xar*)   mkdir -p "$WORK_DIR/x"; mv "$WORK_DIR/pkg.bin" "$WORK_DIR/x/install.pkg" ;;
    bzip2*|*disk\ image*)
            mp=$(hdiutil attach "$WORK_DIR/pkg.bin" -nobrowse -noautoopen 2>/dev/null | grep -o '/Volumes/.*' | tail -1)
            [[ -n "$mp" ]] && mkdir -p "$WORK_DIR/x" && cp -R "$mp/"* "$WORK_DIR/x/" && hdiutil detach "$mp" -force -quiet ;;
    *)      finish $EXIT_CRITICAL "CRITICAL: downloaded file is not a ZIP/PKG/DMG - check PKG_URL" ;;
esac

INSTALL_PKG=$(find "$WORK_DIR/x" -maxdepth 3 -iname '*.pkg' 2>/dev/null | head -1)
[[ -n "$INSTALL_PKG" ]] || finish $EXIT_CRITICAL "CRITICAL: no install.pkg found in the downloaded package"
log "Found installer: $INSTALL_PKG"

# 3. settings.ini: use the bundled one if present, else write the Israel site ini
if [[ -f "$(dirname "$INSTALL_PKG")/settings.ini" ]]; then
    cp "$(dirname "$INSTALL_PKG")/settings.ini" /tmp/settings.ini
    log "Using settings.ini bundled in the package"
else
    write_settings_ini
    log "Wrote Israel/Helfy settings.ini (SITEID=690373) to /tmp"
fi

# 4. Install
log "Running: installer -pkg '$INSTALL_PKG' -target /"
if ! /usr/sbin/installer -pkg "$INSTALL_PKG" -target / >> "$LOG_FILE" 2>&1; then
    finish $EXIT_CRITICAL "CRITICAL: installer -pkg failed - see log"
fi

# 5. Verify
waited=0
until is_installed || (( waited >= VERIFY_TIMEOUT )); do
    sleep 5; (( waited += 5 ))
done

if is_installed; then
    finish $EXIT_SUCCESS "OK: N-Sight agent installed and running (PID $(pgrep -x rmmagentd | head -1)) in ${waited}s"
else
    finish $EXIT_WARNING "WARNING: installer completed but rmmagentd not running after ${VERIFY_TIMEOUT}s - check dashboard registration"
fi
