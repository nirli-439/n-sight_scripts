#!/bin/bash
# =============================================================================
# Install_Slack_mac.sh - Install Slack for macOS (/Applications), no Dock changes
# EXIT CODES: 0=Success | 1001=Warning | 1002=Critical
# REQUIRES: Root (sudo); native macOS tools only, Bash 3.2 compatible
# =============================================================================

set -o pipefail

readonly SLACK_URL="https://slack.com/ssb/download-osx-universal"
readonly APP_PATH="/Applications/Slack.app"
readonly BUNDLE_ID="com.tinyspeck.slackmacgap"
readonly TEAM_ID="BQR82RBBHL"
WORK_DIR=""
MOUNT=""
ATTACHED=false

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
ok()   { echo "OK: $1";       exit 0;    }
fail() { echo "CRITICAL: $1"; exit 1002; }

cleanup() {
    if [[ "$ATTACHED" == true ]]; then
        # Never delete a work directory containing a still-mounted image.
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || {
            log "Could not detach $MOUNT; leaving $WORK_DIR for inspection"
            return
        }
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

valid_slack() {
    local app="$1" bundle
    [[ -d "$app" && ! -L "$app" ]] || return 1
    bundle=$(defaults read "${app}/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 1
    [[ "$bundle" == "$BUNDLE_ID" ]] || return 1
    codesign --verify --deep --strict -R \
        "=anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
        "$app" 2>/dev/null || return 1
    spctl --assess --type execute "$app" 2>/dev/null
}

# --- Root check ---
[[ $EUID -eq 0 ]] || fail "Root privileges required"

# Install-only: leave any existing item untouched, including broken/symlink apps.
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    valid_slack "$APP_PATH" || fail "Existing $APP_PATH is not a verified Slack app; left untouched"
    ok "Verified Slack already installed at $APP_PATH; Dock unchanged"
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/slack-install.XXXXXX") || fail "Cannot create private work directory"
MOUNT="$WORK_DIR/mount"
readonly DMG="$WORK_DIR/Slack.dmg"
trap cleanup EXIT
trap 'exit 1002' HUP INT TERM
mkdir "$MOUNT" || fail "Cannot create mount point"

log "Downloading Slack..."
curl --proto '=https' --proto-redir '=https' -fL --retry 3 --retry-delay 5 \
    -o "$DMG" "$SLACK_URL" || fail "Failed to download Slack DMG"

log "Mounting DMG..."
hdiutil attach "$DMG" -readonly -nobrowse -quiet -mountpoint "$MOUNT" 2>/dev/null \
    || fail "Failed to mount Slack DMG"
ATTACHED=true

# Slack's distribution has its app at the volume root; never search other volumes.
src="$MOUNT/Slack.app"
valid_slack "$src" || fail "Downloaded Slack failed bundle, vendor signature or Gatekeeper verification"

# Atomic reservation refuses any item that appeared during download. No removal or
# merging with an unrelated app. A failed copy is left for operator inspection.
mkdir "$APP_PATH" || fail "Cannot reserve $APP_PATH; existing items left untouched"
cp -R "$src/." "$APP_PATH/" || fail "Copy failed; incomplete $APP_PATH left for inspection"
valid_slack "$APP_PATH" || fail "Installed Slack failed verification; left for inspection"

# Slack's updater needs a real console user's ownership, not loginwindow/guests.
owner=$(stat -f '%Su' /dev/console 2>/dev/null)
owner_uid=""
case "$owner" in
    ''|root|loginwindow|_mbsetupuser|Guest|_*) ;;
    *) owner_uid=$(id -u "$owner" 2>/dev/null) ;;
esac
ownership="root:wheel"
if [[ "$owner_uid" =~ ^[0-9]+$ ]] && [[ "$owner_uid" -ge 501 && "$owner_uid" -lt 2147483647 ]]; then
    ownership="${owner}:staff"
fi
chown -R "$ownership" "$APP_PATH" || fail "Failed to set Slack ownership"
log "Ownership set to $ownership"
ok "Verified Slack installed at $APP_PATH; Dock unchanged"
