#!/bin/bash
# Ubuntu: install system-wide Slack Flatpak; preserve existing profiles/data.
# Exits: 0 success, 1002 failure. Does not run Slack as root.
set -o pipefail
fail() { echo "CRITICAL: $*"; exit 1002; }
[[ $EUID -eq 0 ]] || fail "Root privileges required"
umask 022
export DEBIAN_FRONTEND=noninteractive
readonly APP_ID=com.slack.Slack
readonly DESKTOP=/var/lib/flatpak/exports/share/applications/com.slack.Slack.desktop
readonly LAUNCHERS=/usr/local/share/applications
readonly WRAPPER=/usr/local/bin/slack
if ! command -v flatpak >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail 'This installer requires Ubuntu/apt'
    apt-get update -qq && apt-get install -y -qq flatpak || fail 'Could not install Flatpak'
fi
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || fail 'Could not configure Flathub'
if ! flatpak info --system "$APP_ID" >/dev/null 2>&1; then
    flatpak install --system --noninteractive -y flathub "$APP_ID" || fail 'Slack installation failed'
fi
flatpak info --system "$APP_ID" >/dev/null 2>&1 || fail 'Slack not registered after installation'
[[ -f "$DESKTOP" ]] || fail 'Slack desktop launcher is missing'
mkdir -p "$LAUNCHERS" /usr/local/bin || fail 'Cannot create launcher directories'
cp -Lf "$DESKTOP" "$LAUNCHERS/com.slack.Slack.desktop" || fail 'Cannot publish Slack launcher'
chmod 644 "$LAUNCHERS/com.slack.Slack.desktop" || fail 'Cannot set launcher permissions'
printf '#!/bin/sh\nexec /usr/bin/flatpak run com.slack.Slack "$@"\n' > "$WRAPPER" || fail 'Cannot create Slack wrapper'
chmod 755 "$WRAPPER" || fail 'Cannot set wrapper permissions'
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$LAUNCHERS" >/dev/null 2>&1 || true
fi
echo 'OK: Slack installed via Flathub. Run: slack (as your desktop user). Sign-in remains manual.'
