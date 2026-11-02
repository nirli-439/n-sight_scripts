#!/usr/bin/env bash
# Double-click in Finder. macOS shows its standard administrator-login dialog.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script "/bin/bash " & quoted form of (item 1 of argv) with administrator privileges' \
    -e 'end run' \
    "$HERE/Confirm_NSight_Agent_mac.sh"
