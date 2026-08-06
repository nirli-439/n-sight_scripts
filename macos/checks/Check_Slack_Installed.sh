#!/bin/bash
# =============================================================================
# Check_Slack_Installed.sh - Check if Slack is installed on macOS
# =============================================================================
# EXIT CODES: 0=OK (installed) | 1002=CRITICAL (not installed)
# REMEDIATION: Install_Slack_mac.sh
# =============================================================================

set -o pipefail

readonly APP_PATH="/Applications/Slack.app"
readonly BUNDLE_ID="com.tinyspeck.slackmacgap"

# --- Check /Applications (system-wide) ---
if [[ -d "$APP_PATH" ]]; then
    bundle=$(defaults read "${APP_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null)
    if [[ "$bundle" == "$BUNDLE_ID" || "$bundle" == *"slack"* ]]; then
        ver=$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
        echo "OK: Slack v${ver} installed at $APP_PATH"
        exit 0
    fi
fi

# --- Check user ~/Applications folders ---
for user_home in /Users/*/; do
    [[ "$(basename "$user_home")" == "Shared" ]] && continue
    user_app="${user_home}Applications/Slack.app"
    if [[ -d "$user_app" ]]; then
        bundle=$(defaults read "${user_app}/Contents/Info" CFBundleIdentifier 2>/dev/null)
        if [[ "$bundle" == "$BUNDLE_ID" || "$bundle" == *"slack"* ]]; then
            ver=$(defaults read "${user_app}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
            echo "OK: Slack v${ver} installed at $user_app (user-level — consider moving to /Applications)"
            exit 0
        fi
    fi
done

# --- Not found ---
echo "CRITICAL: Slack is not installed — run Install_Slack_mac.sh to remediate"
exit 1002
