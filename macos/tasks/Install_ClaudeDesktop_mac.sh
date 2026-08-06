#!/bin/bash
# Install_ClaudeDesktop_mac.sh — Claude.app to /Applications (official universal zip).
# Exit: 0 = OK, 1002 = failure. Pair with a check script for N-Sight.
# Run: sudo bash Install_ClaudeDesktop_mac.sh
#
set -o pipefail

readonly SCRIPT_VERSION="1.0"
readonly RELEASES_JSON_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/ClaudeDesktopInstall_$(date +%Y%m%d_%H%M%S).log"
readonly EXIT_OK=0
readonly EXIT_FAIL=1002

readonly INSTALL_PATH="/Applications/Claude.app"
readonly CLAUDE_BUNDLE_ID="com.anthropic.claudefordesktop"

DOWNLOAD_PATH=""

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

claude_present() {
    [[ -d "$INSTALL_PATH" ]] || return 1
    local bid
    bid=$(defaults read "$INSTALL_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 1
    [[ "$bid" == "$CLAUDE_BUNDLE_ID" ]]
}

cleanup() {
    [[ -n "$DOWNLOAD_PATH" && -f "$DOWNLOAD_PATH" ]] && rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$LOG_DIR" 2>/dev/null
log "Install Claude Desktop macOS v$SCRIPT_VERSION — $(hostname) — $(whoami)"

need_root

if claude_present; then
    v=$(get_version "$INSTALL_PATH")
    log "Already installed: $INSTALL_PATH ($v)"
    echo ""
    echo "OK: Claude already installed (v${v}) at $INSTALL_PATH"
    exit $EXIT_OK
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to parse the release manifest"
fi

log "Fetching release manifest..."
JSON=$(curl -fsSL "$RELEASES_JSON_URL") || die "Failed to download RELEASES.json"
ZIP_URL=$(echo "$JSON" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j['releases'][0]['updateTo']['url'])") || die "Could not parse download URL"

DOWNLOAD_PATH="/tmp/Claude_$(date +%Y%m%d_%H%M%S).zip"
log "Downloading: $ZIP_URL"
curl -fL -o "$DOWNLOAD_PATH" "$ZIP_URL" --progress-bar || die "Download failed"
[[ -f "$DOWNLOAD_PATH" ]] || die "Download missing"

STAGE=$(mktemp -d "/tmp/claude_stage.XXXXXX") || die "mktemp failed"
log "Extracting zip..."
ditto -x -k "$DOWNLOAD_PATH" "$STAGE" || die "Unzip failed"

SRC=""
[[ -d "$STAGE/Claude.app" ]] && SRC="$STAGE/Claude.app"
[[ -z "$SRC" ]] && SRC=$(find "$STAGE" -maxdepth 3 -name "Claude.app" -type d 2>/dev/null | head -1)
[[ -n "$SRC" && -d "$SRC" ]] || die "Claude.app not found in archive"

log "Installing from: $SRC"
[[ -d "$INSTALL_PATH" ]] && rm -rf "$INSTALL_PATH"
ditto "$SRC" "$INSTALL_PATH" || die "Install to /Applications failed"

chown -R root:wheel "$INSTALL_PATH" 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

bid=$(defaults read "$INSTALL_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)
[[ "$bid" == "$CLAUDE_BUNDLE_ID" ]] || die "Unexpected bundle ID: $bid"

rm -rf "$STAGE" 2>/dev/null || true

v=$(get_version "$INSTALL_PATH")
log "Installed Claude $v"
codesign -v "$INSTALL_PATH" 2>/dev/null && log "Code signature OK" || log "Code signature check skipped or failed (non-fatal)"

echo ""
echo "OK: Claude installed (v${v}) at $INSTALL_PATH"
exit $EXIT_OK
