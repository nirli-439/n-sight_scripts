#!/bin/bash
# Safe regression: no app launches, installs or user preference changes.
set -euo pipefail
cd "$(dirname "$0")"
source ./Onboarding_Menu_mac.sh
SELECTED=(1 1 1 1 0 0 1 0 1 1 1 0 1 1)
LOG_FILE=/dev/null
EVENTS=''
run_task() {
    EVENTS="$EVENTS task-$1"
    RESULTS[$1]=Done
    [[ $1 != 2 ]] || { RESULTS[$1]=Failed; return 1; }
}
launch_app() {
    [[ "$EVENTS" == *' task-13'* ]] || { echo 'FAIL: launched before installs finished'; exit 1; }
    EVENTS="$EVENTS launch-$1"
    [[ "$1" != /Applications/Slack.app ]]
}
popup() {
    EVENTS="$EVENTS popup"
    [[ "$2" == *'launch requested'* && "$2" == *'launch failed'* ]] || exit 1
}
run_selected && { echo 'FAIL: failure lost'; exit 1; }
[[ "$EVENTS" == *'launch-/Applications/Google Chrome.app'* ]]
[[ "$EVENTS" == *'launch-/Applications/NirTab.app'* ]]
[[ "$EVENTS" != *'launch-/Applications/Google Drive.app'* ]]
[[ "$EVENTS" == *'launch-/Applications/1Password.app'*'launch-/Applications/NirTab.app popup' ]]
[[ ${RESULTS[3]} == *'launch failed'* ]]
(
    source ./Onboarding_Menu_mac.sh
    open() { echo 'FAIL: open called for missing app'; exit 1; }
    launch_app /nonexistent/NotInstalled.app && exit 1
    exit 0
)
echo 'PASS: GUI launches only after queue, successful selections only, failures visible, one final summary'
