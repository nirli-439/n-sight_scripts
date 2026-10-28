#!/bin/bash
# Install NirTab v0.15 from nirli-439/NirTab; macOS 14+, Intel/Apple Silicon.
# Exit: 0=installed/already present, 1002=failure. No Dock or TCC changes.
# Self-signed release: first Open/Gatekeeper approval and AX/Screen Recording
# permissions remain manual. Never disable Gatekeeper or re-sign the app.
set -o pipefail
readonly APP_PATH=/Applications/NirTab.app
readonly BUNDLE_ID=com.nir.nirtab
readonly URL=https://github.com/nirli-439/NirTab/releases/download/v0.15/NirTab-0.15.zip
readonly SHA256=6271df477e1dc63ab24fc00855aa7eab363f30309cf9011034f7dca759d6baa2
WORK=''
fail() { echo "CRITICAL: $*"; exit 1002; }
valid_app() {
    [[ -d "$1" && ! -L "$1" ]] || return 1
    [[ "$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]] || return 1
    codesign --verify --deep --strict "$1"
}
[[ $EUID -eq 0 ]] || fail "Run as root (sudo)"
version=$(sw_vers -productVersion) || fail 'Cannot read macOS version'
major=${version%%.*}
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 14 ]] || fail 'NirTab requires macOS 14 or later'
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    valid_app "$APP_PATH" || fail 'Existing NirTab is not a valid signed app; left untouched'
    echo 'OK: NirTab already installed. Use its Check for Updates menu for updates.'
    exit 0
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nirtab-install.XXXXXX") || fail 'Cannot create work directory'
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1002' HUP INT TERM
curl --proto '=https' --proto-redir '=https' -fL --retry 3 --connect-timeout 30 --max-time 180 \
    "$URL" -o "$WORK/NirTab.zip" || fail 'Download failed'
printf '%s  %s\n' "$SHA256" "$WORK/NirTab.zip" | shasum -a 256 -c - || fail 'Release checksum mismatch'
ditto -x -k "$WORK/NirTab.zip" "$WORK/unpacked" || fail 'Archive extraction failed'
src="$WORK/unpacked/NirTab.app"
valid_app "$src" || fail 'Downloaded NirTab failed bundle/signature validation'
mkdir "$APP_PATH" || fail 'Cannot reserve install path; existing items left untouched'
ditto "$src" "$APP_PATH" || fail 'Copy failed; incomplete app left for inspection'
valid_app "$APP_PATH" || fail 'Installed NirTab verification failed'
echo 'OK: NirTab v0.15 installed. Dock unchanged.'
echo 'NEXT: Right-click NirTab in Applications > Open, then approve Accessibility and Screen Recording in its Setup Checklist.'
echo 'The release is self-signed, not notarized. Gatekeeper and privacy permissions were not bypassed.'
