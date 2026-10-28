#!/bin/bash
# Safe checks: source menu functions; never install or remove anything.
set -eu
cd "$(dirname "$0")"
[[ -f Onboarding_Menu_mac.sh ]] || { echo 'FAIL: onboarding menu missing'; exit 1; }
source ./Onboarding_Menu_mac.sh
[[ "${NAMES[*]}" == 'Bitdefender Google Chrome Google Drive Slack Create admin mac Homebrew Twingate Remove N-sight agent' ]]
[[ "${SELECTED[*]}" == '1 1 1 1 1 1 1 0' ]]
toggle 7; [[ ${SELECTED[7]} == 1 ]]; toggle 7
SELECTED=(1 0 1 0 0 0 1 0)
CALLS=''
run_task() { CALLS="$CALLS $1"; [[ $1 != 2 ]]; }
popup() { :; }
LOG_FILE=/dev/null
run_selected && { echo 'FAIL: failure not propagated'; exit 1; }
[[ "$CALLS" == ' 0 2 6' ]] || { echo "FAIL: order: $CALLS"; exit 1; }
SELECTED=(0 0 0 0 0 0 0 1)
confirm_remove() { return 1; }
CALLS=''
run_selected || true
[[ -z "$CALLS" ]] || { echo 'FAIL: removal ran without confirmation'; exit 1; }
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
    SELECTED=(1 0 0 0 0 0 0 0)
    fetch() { return 1; }
    prepare_tasks && exit 1
    exit 0
)
echo 'PASS: menu order, defaults, toggling, sequential execution, failure continuation, removal guard, wrapped exit codes and download failure'
