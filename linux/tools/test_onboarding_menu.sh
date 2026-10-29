#!/bin/bash
# Safe orchestration checks; no sudo, package installs or app launches.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f Onboarding_Menu_linux.sh ]] || { echo 'FAIL: Linux menu missing'; exit 1; }
source ./Onboarding_Menu_linux.sh
[[ "${NAMES[*]}" == 'Google Chrome Bitdefender Screen lock (15 minutes) Git setup Slack Claude Code Codex CLI Antigravity Docker + Compose Twingate MySQL Workbench System + firmware updates Offboard local users' ]] || exit 1
[[ "${SELECTED[*]}" == '1 1 1 1 1 1 1 1 1 1 1 1 0' ]] || exit 1
SELECTED[12]=1; select_all; [[ ${SELECTED[12]} == 0 ]] || exit 1
SELECTED=(1 1 1 1 1 1 1 1 1 1 1 1 0)
EVENTS=''
LOG_FILE=/dev/null
export DISPLAY=:test
run_task() { EVENTS="$EVENTS task-$1"; RESULTS[$1]=Done; [[ $1 != 1 ]]; }
launch_app() { [[ "$EVENTS" == *task-11* ]] || exit 1; EVENTS="$EVENTS launch-$1"; }
finish_popup() { [[ "$EVENTS" == *task-11* ]] || exit 1; EVENTS="$EVENTS popup"; }
run_selected && { echo 'FAIL: task failure lost'; exit 1; }
[[ "$EVENTS" == ' task-0 task-1 task-2 task-3 task-4 task-5 task-6 task-7 task-8 task-9 task-10 task-11 launch-0 launch-4 launch-7 launch-10 popup' ]] || { echo "FAIL: wrong sequence $EVENTS"; exit 1; }
toggle 9; [[ ${SELECTED[9]} == 0 ]]; toggle 9; [[ ${SELECTED[9]} == 1 ]]
(
    source ./Onboarding_Menu_linux.sh
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/linux-menu-test.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    fetch() { return 1; }
    prepare_tasks && exit 1
    SELECTED=(0 0 0 0 0 1 0 0 0 0)
    printf '#!/bin/bash\nprintf "user-task:%%s\\n" "$1"\n' > "$WORK/task-5.sh"
    sudo() { echo 'FAIL: user CLI installer elevated'; exit 1; }
    run_task 5
    [[ ${RESULTS[5]} == Done ]]
    SELECTED=(0 0 0 0 0 0 0 0 0 0 0 0 1)
    fetch() { printf 'raise SystemExit(99)\n' > "$2"; }
    prepare_tasks
    [[ -f "$WORK/task-12.py" ]] || exit 1
    sudo() { [[ "$1" == python3 && "$2" == "$WORK/task-12.py" && "$3" == --keep && "$4" == "$(id -un)" ]]; }
    run_task 12
    [[ ${RESULTS[12]} == Done ]] || exit 1
)
echo 'PASS: defaults, ordered queue, failure continuation, user-scoped AI install, downloads fail closed, launch after queue and one summary'
