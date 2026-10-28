#!/bin/bash
# Safe checks: source menu functions; never install or remove anything.
set -eu
cd "$(dirname "$0")"
[[ -f Onboarding_Menu_mac.sh ]] || { echo 'FAIL: onboarding menu missing'; exit 1; }
source ./Onboarding_Menu_mac.sh
[[ "${NAMES[*]}" == 'Bitdefender Google Chrome Google Drive Slack Create admin mac Homebrew Twingate Remove N-sight agent Claude Desktop ChatGPT Desktop Gemini Desktop Git setup 1Password NirTab' ]]
[[ "${SELECTED[*]}" == '1 1 1 1 1 1 1 0 0 0 0 0 0 0' ]]
toggle 7; [[ ${SELECTED[7]} == 1 ]]; toggle 7
SELECTED=(1 0 1 0 0 0 1 0 1 1 1 1 1 1)
CALLS=''
run_task() { CALLS="$CALLS $1"; [[ $1 != 2 ]]; }
POPUPS=0
popup() {
    POPUPS=$((POPUPS + 1))
    [[ "$CALLS" == ' 0 2 6 8 9 10 11 12 13' ]] || { echo 'FAIL: popup before queue finished'; exit 1; }
    [[ "$2" == *'Google Drive:'* && "$2" == *'1Password:'* ]] || { echo 'FAIL: missing final summary'; exit 1; }
}
LOG_FILE=/dev/null
run_selected && { echo 'FAIL: failure not propagated'; exit 1; }
[[ "$CALLS" == ' 0 2 6 8 9 10 11 12 13' ]] || { echo "FAIL: order: $CALLS"; exit 1; }
[[ $POPUPS == 1 ]] || { echo 'FAIL: expected one final popup'; exit 1; }
POPUPS=0
popup() { POPUPS=$((POPUPS + 1)); [[ "$2" == *'Remove N-sight agent: Cancelled'* ]]; }
SELECTED=(0 0 0 0 0 0 0 1)
confirm_remove() { return 1; }
CALLS=''
run_selected || true
[[ -z "$CALLS" ]] || { echo 'FAIL: removal ran without confirmation'; exit 1; }
[[ $POPUPS == 1 ]] || { echo 'FAIL: cancelled-only run needs one final summary'; exit 1; }
(
    source ./Onboarding_Menu_mac.sh
    SELECTED=(1)
    run_task() { RESULTS[$1]=Done; }
    POPUPS=0
    popup() { POPUPS=$((POPUPS + 1)); [[ "$1" == 'Setup finished' && "$2" == *'Bitdefender: Done'* ]]; }
    run_selected
    [[ $POPUPS == 1 ]]
    SELECTED=(0)
    popup() { POPUPS=$((POPUPS + 1)); [[ "$1" == 'No tasks run' ]]; }
    run_selected
    [[ $POPUPS == 2 ]]
)
# Exercise real status decoding without running privileged commands.
(
    source ./Onboarding_Menu_mac.sh
    WORK=/unused
    sudo() { return 233; }
    run_task 0 && exit 1
    [[ ${RESULTS[0]} == 'Warning - check output' ]]
    sudo() { return 234; }
    run_task 0 && exit 1
    [[ ${RESULTS[0]} == 'Failed (exit 234)' ]]
    sudo() { return 0; }
    run_task 0
    [[ ${RESULTS[0]} == Done ]]
    sudo() { [[ "$*" == '/bin/bash /unused/task-7.sh --no-popup' ]]; }
    run_task 7
    [[ ${RESULTS[7]} == Done ]]
    SELECTED=(1 0 0 0 0 0 0 0)
    fetch() { return 1; }
    prepare_tasks && exit 1
    exit 0
)
echo 'PASS: menu order, defaults, toggling, sequential execution, failure continuation, removal guard, wrapped exit codes and download failure'
