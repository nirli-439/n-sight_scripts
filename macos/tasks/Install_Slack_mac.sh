#!/bin/bash
# =============================================================================
# Install_Slack_mac.sh - Install Slack for macOS (/Applications)
# =============================================================================
# EXIT CODES: 0=Success | 1001=Warning | 1002=Critical
# REQUIRES: Root (sudo)
# =============================================================================

set -o pipefail

readonly SLACK_URL="https://slack.com/ssb/download-osx-universal"
readonly DMG="/tmp/Slack.dmg"
readonly MOUNT="/Volumes/Slack"
readonly APP_PATH="/Applications/Slack.app"
readonly BUNDLE_ID="com.tinyspeck.slackmacgap"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
ok()   { echo "OK: $1";       exit 0;    }
fail() { echo "CRITICAL: $1"; exit 1002; }

cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -f "$DMG" 2>/dev/null || true
}
trap cleanup EXIT

# --- Root check ---
[[ $EUID -eq 0 ]] || fail "Root privileges required"

log "Host: $(hostname) | macOS: $(sw_vers -productVersion) | Arch: $(uname -m)"

# --- Already installed? ---
if [[ -d "$APP_PATH" ]]; then
    ver=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    ok "Slack already installed (v${ver}) at $APP_PATH"
fi

# --- Download ---
log "Downloading Slack..."
curl -fL --retry 3 --retry-delay 5 -o "$DMG" "$SLACK_URL" \
    || fail "Failed to download Slack DMG"

# --- Mount ---
log "Mounting DMG..."
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT" 2>/dev/null \
    || fail "Failed to mount Slack DMG"

# --- Install ---
log "Installing to /Applications..."
src=$(find /Volumes -maxdepth 2 -name "Slack.app" -type d 2>/dev/null | head -1)
[[ -d "$src" ]] || fail "Slack.app not found on mounted DMG"

rm -rf "$APP_PATH" 2>/dev/null
cp -R "$src" /Applications/ || fail "Failed to copy Slack.app to /Applications"

# Set ownership — Slack's updater runs as the console user, not root
owner=$(stat -f '%Su' /dev/console 2>/dev/null)
if [[ -n "$owner" && "$owner" != "root" ]]; then
    chown -R "${owner}:staff" "$APP_PATH" 2>/dev/null
    log "Ownership set to ${owner}:staff"
else
    chown -R root:wheel "$APP_PATH" 2>/dev/null
fi

xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

# --- Verify ---
bundle=$(defaults read "${APP_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
[[ "$bundle" == "$BUNDLE_ID" ]] || fail "Bundle ID mismatch after install: $bundle"

ver=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
ok "Slack installed successfully (v${ver}) at $APP_PATH"
