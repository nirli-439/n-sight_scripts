#!/bin/bash
# =============================================================================
# Install_Dropbox_mac.sh — Dropbox via official enterprise PKG (silent, all users)
# =============================================================================
#
# SYNOPSIS:
#     Downloads and installs Dropbox for macOS using the enterprise PKG from
#     Dropbox Help (Install Dropbox for all team members).
#
# DESCRIPTION:
#     Remediation script for N-Sight when a check reports Dropbox is missing.
#     - Picks Intel (x86_64) or Apple Silicon (arm64) PKG URL
#     - Installs with installer(8) to /
#     - Verifies /Applications/Dropbox.app
#     - Sets ownership root:wheel and clears quarantine
#
# EXIT CODES:
#     0    = Success
#     1002 = Critical / failure
#
# EXECUTION:
#     sudo bash /path/to/Install_Dropbox_mac.sh
#     curl -fsSL "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/macos/tasks/Install_Dropbox_mac.sh" | sudo bash
#
# NOTES:
#     Requires root. Pair with Check_Dropbox_Installed.sh when available.
#     Vendor: https://help.dropbox.com/installs/enterprise-installer
#
# =============================================================================

set -o pipefail

readonly SCRIPT_NAME="Install Dropbox macOS (Enterprise PKG)"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/DropboxInstall_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_CRITICAL=1002

readonly PKG_PATH="/tmp/DropboxEnterprise.pkg"
readonly INSTALL_PATH="/Applications/Dropbox.app"
# Typical bundle id for Dropbox desktop (verify after install)
readonly DROPBOX_BUNDLE_ID="com.getdropbox.dropbox"

readonly URL_INTEL="https://client.dropbox.com/desktop/desktop-dropbox/requestdownload?install_type=enterprise_install&platform=mac&arch=x86_64"
readonly URL_ARM="https://client.dropbox.com/desktop/desktop-dropbox/requestdownload?install_type=enterprise_install&platform=mac&arch=arm64"

log() {
    local level="${2:-INFO}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [$level] $1"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null
}

write_summary() {
    echo ""
    echo "${1}: ${2}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "This script must run as root (sudo)" "ERROR"
        write_summary "CRITICAL" "Root privileges required"
        exit $EXIT_CRITICAL
    fi
}

get_pkg_url() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm64)
            log "Architecture: arm64 — Apple Silicon PKG"
            echo "$URL_ARM"
            ;;
        x86_64)
            log "Architecture: x86_64 — Intel PKG"
            echo "$URL_INTEL"
            ;;
        *)
            log "Unknown architecture: $arch — defaulting to Intel PKG" "WARNING"
            echo "$URL_INTEL"
            ;;
    esac
}

dropbox_installed() {
    if [[ ! -d "$INSTALL_PATH" ]]; then
        return 1
    fi
    local bid
    bid=$(defaults read "$INSTALL_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 1
    if [[ "$bid" == "$DROPBOX_BUNDLE_ID" ]] || [[ "$bid" == *dropbox* ]]; then
        return 0
    fi
    return 1
}

get_version() {
    defaults read "$INSTALL_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown"
}

cleanup() {
    rm -f "$PKG_PATH" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$LOG_DIR" 2>/dev/null

log "=========================================="
log "$SCRIPT_NAME v$SCRIPT_VERSION"
log "=========================================="
log "Host: $(hostname)"
log "macOS: $(sw_vers -productVersion 2>/dev/null)"
log "User: $(whoami)"
log "Log: $LOG_FILE"

check_root

if dropbox_installed; then
    v=$(get_version)
    log "Dropbox already present at $INSTALL_PATH ($v)"
    write_summary "OK" "Dropbox already installed (v${v})"
    echo "Path: $INSTALL_PATH"
    exit $EXIT_SUCCESS
fi

PKG_URL=$(get_pkg_url)
log "Downloading enterprise PKG..."
rm -f "$PKG_PATH"

if ! curl -fL --retry 5 --retry-delay 5 -o "$PKG_PATH" "$PKG_URL" --progress-bar; then
    log "Download failed" "ERROR"
    write_summary "CRITICAL" "Failed to download Dropbox PKG"
    exit $EXIT_CRITICAL
fi

if [[ ! -f "$PKG_PATH" ]]; then
    log "PKG missing after download" "ERROR"
    write_summary "CRITICAL" "Dropbox PKG not found"
    exit $EXIT_CRITICAL
fi

log "Installing PKG to / ..."
if ! installer -pkg "$PKG_PATH" -target /; then
    log "installer failed" "ERROR"
    write_summary "CRITICAL" "Dropbox PKG installation failed"
    exit $EXIT_CRITICAL
fi

if ! dropbox_installed; then
    log "Verification failed: $INSTALL_PATH missing or wrong bundle ID" "ERROR"
    write_summary "CRITICAL" "Dropbox installation verification failed"
    exit $EXIT_CRITICAL
fi

chown -R root:wheel "$INSTALL_PATH" 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

v=$(get_version)
log "Installed Dropbox v$v"

if codesign -v "$INSTALL_PATH" 2>/dev/null; then
    log "Code signature: valid"
else
    log "Code signature: could not verify (non-fatal)" "WARNING"
fi

log "=========================================="
log "Done"
write_summary "OK" "Dropbox installed (v${v})"
echo "Path: $INSTALL_PATH"
echo "NOTE: Users must sign in to Dropbox on first launch if not yet linked."

exit $EXIT_SUCCESS
