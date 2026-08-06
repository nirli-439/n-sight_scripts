#!/bin/bash
# Install_Canva_mac.sh — Canva.app to /Applications (official ARM64 DMG).
# Exit: 0 = OK, 1002 = failure. Pair with a check script for N-Sight.
# Run: sudo bash Install_Canva_mac.sh
# Requires: Apple Silicon (arm64) Mac only.
#
set -o pipefail

readonly SCRIPT_VERSION="1.0"
readonly DMG_URL="https://desktop.canva.com/Canva-arm64.dmg"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/CanvaInstall_$(date +%Y%m%d_%H%M%S).log"
readonly EXIT_OK=0
readonly EXIT_FAIL=1002

readonly INSTALL_PATH="/Applications/Canva.app"
readonly CANVA_BUNDLE_ID="com.canva.CanvaDesktop"

DOWNLOAD_PATH=""
MOUNT_POINT=""

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${1}"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

die() {
    log "ERROR: $1"
    echo ""
    echo "CRITICAL: $1"
    exit $EXIT_FAIL
}

need_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (sudo)"
}

get_version() {
    defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown"
}

canva_present() {
    [[ -d "$INSTALL_PATH" ]] || return 1
    local bid
    bid=$(defaults read "$INSTALL_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 1
    [[ "$bid" == "$CANVA_BUNDLE_ID" ]]
}

cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    [[ -n "$DOWNLOAD_PATH" && -f "$DOWNLOAD_PATH" ]] && rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$LOG_DIR" 2>/dev/null
log "Install Canva Desktop macOS v$SCRIPT_VERSION — $(hostname) — $(whoami)"

need_root

# Verify Apple Silicon
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
    die "This script only supports Apple Silicon (arm64) Macs. Detected: $ARCH"
fi
log "Architecture: $ARCH — OK"

if canva_present; then
    v=$(get_version "$INSTALL_PATH")
    log "Already installed: $INSTALL_PATH ($v)"
    echo ""
    echo "OK: Canva already installed (v${v}) at $INSTALL_PATH"
    exit $EXIT_OK
fi

DOWNLOAD_PATH="/tmp/Canva_$(date +%Y%m%d_%H%M%S).dmg"
log "Downloading: $DMG_URL"
curl -fL -o "$DOWNLOAD_PATH" "$DMG_URL" --progress-bar || die "Download failed"
[[ -f "$DOWNLOAD_PATH" ]] || die "Download missing"

log "Mounting DMG..."
MOUNT_OUTPUT=$(hdiutil attach "$DOWNLOAD_PATH" -nobrowse -noverify -noautoopen 2>&1) || die "Failed to mount DMG"
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk 'END{print $NF}')
[[ -d "$MOUNT_POINT" ]] || die "Mount point not found: $MOUNT_POINT"
log "Mounted at: $MOUNT_POINT"

SRC=""
[[ -d "$MOUNT_POINT/Canva.app" ]] && SRC="$MOUNT_POINT/Canva.app"
[[ -z "$SRC" ]] && SRC=$(find "$MOUNT_POINT" -maxdepth 3 -name "Canva.app" -type d 2>/dev/null | head -1)
[[ -n "$SRC" && -d "$SRC" ]] || die "Canva.app not found in DMG"

log "Installing from: $SRC"
[[ -d "$INSTALL_PATH" ]] && rm -rf "$INSTALL_PATH"
ditto "$SRC" "$INSTALL_PATH" || die "Install to /Applications failed"

chown -R root:wheel "$INSTALL_PATH" 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

bid=$(defaults read "$INSTALL_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)
[[ "$bid" == "$CANVA_BUNDLE_ID" ]] || die "Unexpected bundle ID: $bid"

v=$(get_version "$INSTALL_PATH")
log "Installed Canva $v"
codesign -v "$INSTALL_PATH" 2>/dev/null && log "Code signature OK" || log "Code signature check skipped or failed (non-fatal)"

echo ""
echo "OK: Canva installed (v${v}) at $INSTALL_PATH"
exit $EXIT_OK
