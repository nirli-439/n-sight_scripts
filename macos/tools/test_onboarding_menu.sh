#!/bin/bash
# Safe checks: source menu functions; never install or remove anything, no sudo.
set -eu
cd "$(dirname "$0")"
[[ -f Onboarding_Menu_mac.sh ]] || { echo 'FAIL: onboarding menu missing'; exit 1; }
source ./Onboarding_Menu_mac.sh
n=${#NAMES[@]}
[[ $n == 22 && ${#PATHS[@]} == $n && ${#SELECTED[@]} == $n && ${#TIMEOUTS[@]} == $n && ${#APPS[@]} == $n && ${#RESULTS[@]} == $n ]] \
    || { echo 'FAIL: item arrays out of sync'; exit 1; }
[[ "${NAMES[$I_NAME]}" == 'Computer name (IA-xxx)' && "${NAMES[$I_AGENT]}" == 'N-sight agent' && "${NAMES[$I_REMOVE]}" == 'Remove N-sight agent' ]]
[[ $I_NAME -lt $I_AGENT && $I_AGENT -lt 3 && "${NAMES[3]}" == Bitdefender ]] || { echo 'FAIL: name -> agent -> Bitdefender order'; exit 1; }
[[ "${SELECTED[*]}" == '1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 1 1 1 1 0 0' ]] || { echo 'FAIL: default selections'; exit 1; }
for p in "${PATHS[@]}"; do [[ -z "$p" || -f "../$p" ]] || { echo "FAIL: missing $p"; exit 1; }; done
toggle 21; [[ ${SELECTED[21]} == 1 ]]; toggle 21
final_checks() { echo 'OK   stub'; }
LOG_FILE=/dev/null

# Sequential order, failure continuation, one popup after the queue.
SELECTED=(0 1 0 1 0 0 1 0 1 0 1 1 1 1 1 1 1 0 0 0 0 0)
CALLS=''
launch_app() { :; }
run_task() { CALLS="$CALLS $1"; [[ $1 != 3 ]]; }
POPUPS=0
popup() {
    POPUPS=$((POPUPS + 1))
    [[ "$CALLS" == ' 1 3 6 8 10 11 12 13 14 15 16' ]] || { echo 'FAIL: popup before queue finished'; exit 1; }
    [[ "$2" == *'Bitdefender:'* && "$2" == *'1Password:'* && "$2" == *'Final checks'* ]] || { echo 'FAIL: missing final summary'; exit 1; }
}
run_selected && { echo 'FAIL: failure not propagated'; exit 1; }
[[ "$CALLS" == ' 1 3 6 8 10 11 12 13 14 15 16' ]] || { echo "FAIL: order: $CALLS"; exit 1; }
[[ $POPUPS == 1 ]] || { echo 'FAIL: expected one final popup'; exit 1; }

# Up-front questions: removal guard, ADMIN guard, invalid asset key, agent skip.
(
    source ./Onboarding_Menu_mac.sh
    SELECTED=(1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1)
    HOME=$(mktemp -d); mkdir -p "$HOME/Downloads"
    confirm_remove() { return 1; }
    download_agent_pkg() { return 1; }   # never download the real agent in tests
    lookup_asset_key() { :; }            # serial not in the map -> prompt path
    scutil() { echo OLD-NAME; }
    serial_number() { echo C02TEST; }
    printf 'ia 12\nno\ns\n' | {
        NEW_NAME='' ; collect_inputs
        [[ ${SELECTED[1]} == 0 && ${RESULTS[1]} == 'Skipped - invalid asset key' ]] || { echo "FAIL: invalid key ${RESULTS[1]}"; exit 1; }
        [[ ${SELECTED[2]} == 0 && ${RESULTS[2]} == 'Skipped - no agent package' ]] || { echo 'FAIL: agent skip'; exit 1; }
        [[ ${SELECTED[0]} == 0 && ${SELECTED[21]} == 0 && ${RESULTS[21]} == Cancelled ]] || { echo 'FAIL: guards'; exit 1; }
    }
    SELECTED[1]=1; NEW_NAME=''
    printf 'ia-123\n' | { collect_inputs; [[ $NEW_NAME == IA-123 && ${SELECTED[1]} == 1 ]] || { echo 'FAIL: valid key'; exit 1; }; }
    scutil() { echo IA-77; }
    printf '\n' | { NEW_NAME=''; collect_inputs; [[ $NEW_NAME == IA-77 ]] || { echo 'FAIL: keep IA name'; exit 1; }; }
    touch "$HOME/Downloads/OSX_AGENT_TEST_RW.ZIP"; SELECTED[2]=1; NEW_NAME=IA-1
    collect_inputs </dev/null
    [[ $AGENT_PKG == "$HOME/Downloads/OSX_AGENT_TEST_RW.ZIP" ]] || { echo 'FAIL: agent package'; exit 1; }
    rm -rf "$HOME"
)

# Exit-code decoding through the real runner (sudo stubbed, nothing privileged runs).
(
    source ./Onboarding_Menu_mac.sh
    WORK=$(mktemp -d); LOG_FILE=/dev/null
    sudo() { return 233; };  run_task 3 && exit 1; [[ ${RESULTS[3]} == 'Warning - check output' ]]
    sudo() { return 234; };  run_task 3 && exit 1; [[ ${RESULTS[3]} == 'Failed (exit 234)' ]]
    sudo() { return 0; };    run_task 3;           [[ ${RESULTS[3]} == Done ]]
    sudo() { [[ "$*" == "/bin/bash $WORK/task-21.sh --no-popup" ]]; }; run_task 21; [[ ${RESULTS[21]} == Done ]]
    NEW_NAME=IA-9; sudo() { [[ "$*" == "/bin/bash $WORK/task-1.sh IA-9" ]]; }; run_task 1; [[ ${RESULTS[1]} == Done ]]
    AGENT_PKG=/x/OSX_AGENT_RW.ZIP; sudo() { [[ "$*" == "/bin/bash $WORK/task-2.sh /x/OSX_AGENT_RW.ZIP" ]]; }; run_task 2; [[ ${RESULTS[2]} == Done ]]
    # A hung task is killed after its timeout and the result says so.
    TIMEOUTS[3]=1; sudo() { sleep 30; }
    start=$(date +%s); run_task 3 && exit 1; [[ $(( $(date +%s) - start )) -lt 10 && ${RESULTS[3]} == 'Timed out after 1s' ]] || { echo 'FAIL: timeout'; exit 1; }
    SELECTED=(0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    fetch() { return 1; }
    unset ONBOARD_SRC
    prepare_tasks >/dev/null && exit 1
    # Snapshot staging (onboard.sh): copies from ONBOARD_SRC, never downloads.
    ONBOARD_SRC=$(cd ../.. && pwd)
    prepare_tasks; [[ -s "$WORK/task-3.sh" ]]
    rm -rf "$WORK"; exit 0
)
# Asset map: the Mac's own serial resolves to its IA key; unknown serial -> empty (prompt).
(
    source ./Onboarding_Menu_mac.sh
    WORK=$(mktemp -d); ONBOARD_SRC=$(cd ../.. && pwd)
    fetch() { return 1; }   # offline: use the snapshot copy
    serial_number() { echo L6741JHG6W; }
    [[ "$(lookup_asset_key)" == IA-3771 ]] || { echo 'FAIL: asset lookup'; exit 1; }
    serial_number() { echo NOTAREALSERIAL; }
    [[ -z "$(lookup_asset_key)" ]] || { echo 'FAIL: unknown serial'; exit 1; }
    grep -q L6741JHG6W ../assets/mac-asset-map.tsv && { echo 'FAIL: plain serial in public map'; exit 1; }
    rm -rf "$WORK"; exit 0
)
# Chrome default-browser detection parses LaunchServices output.
(
    source ./Onboarding_Menu_mac.sh
    ls_handlers() { printf '(\n {\n LSHandlerPreferredVersions = { LSHandlerRoleAll = "-"; };\n LSHandlerRoleAll = "com.google.chrome";\n LSHandlerURLScheme = https;\n }\n)\n'; }
    chrome_is_default
    ls_handlers() { printf '( { LSHandlerRoleAll = "com.apple.safari"; LSHandlerURLScheme = https; } )\n'; }
    chrome_is_default && exit 1
    exit 0
)
echo 'PASS: layout, defaults, order, failure continuation, up-front questions, exit codes, timeout kill, staging and Chrome default detection'
