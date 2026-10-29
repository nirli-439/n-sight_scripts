#!/bin/bash
# Ubuntu 22.04+ technician onboarding. Run as the desktop user, NOT sudo.
# Downloads are staged before running. Root tasks get umask 022; logs stay private.
set -o pipefail
BASE_URL=https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux
NAMES=('Google Chrome' 'Bitdefender' 'Screen lock (15 minutes)' 'Git setup' 'Slack' 'Claude Code' 'Codex CLI' 'Antigravity' 'Docker + Compose' 'Twingate' 'MySQL Workbench' 'System + firmware updates' 'Offboard local users' 'Enable SSH')
PATHS=('tasks/Install_Chrome_linux.sh' 'tasks/Install_Bitdefender_linux.sh' 'tasks/Remediate_ScreenLock_Timeout_linux.sh' '' 'tasks/Install_Slack_linux.sh' 'tools/Install_AI_Tool_linux.sh' 'tools/Install_AI_Tool_linux.sh' 'tools/Install_AI_Tool_linux.sh' 'tasks/Install_Docker_linux.sh' 'tasks/Install_Twingate_linux.sh' 'tasks/Install_MySQLWorkbench_linux.sh' 'tasks/Update_System_Firmware_linux.sh' 'tools/Offboard_Users_linux.py' 'tasks/Enable_SSH_linux.sh')
ARGS=('' '' '' '' '' claude-code codex antigravity '' '' '' '' '' '')
SELECTED=(1 1 1 1 1 1 1 1 1 1 1 1 0 1)
RESULTS=(Ready Ready Ready Ready Ready Ready Ready Ready Ready Ready Ready Ready Optional Ready)

toggle() { SELECTED[$1]=$((1 - SELECTED[$1])); }
select_all() {
    local i
    for ((i=0; i<${#NAMES[@]}; i++)); do SELECTED[$i]=1; done
    SELECTED[12]=0  # Account deletion must never join a normal setup run.
}
fetch() {
    curl --proto '=https' --proto-redir '=https' -fSL --retry 3 --connect-timeout 30 --max-time 180 "$1" -o "$2"
}

finish_popup() {
    # Use only the existing user desktop session; never run GUI tools with sudo.
    printf '\n%s\n%s\n' "$1" "$2"
    if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v zenity >/dev/null 2>&1; then
        zenity --info --title="$1" --text="$2" --no-markup --width=650 >/dev/null 2>&1 || true
    elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v notify-send >/dev/null 2>&1; then
        notify-send "$1" "$2" || true
    fi
}

setup_git() {
    local name email host login
    if ! git --version >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git || return 1
    fi
    host=$(hostname) || return 1
    login=$(id -un) || return 1
    [[ -n "$host" && "$host" != *[!a-zA-Z0-9.-]* && -n "$login" && "$login" != *[!a-zA-Z0-9_.-]* ]] || return 1
    name=$(git config --global user.name 2>/dev/null || true)
    email=$(git config --global user.email 2>/dev/null || true)
    if [[ -z "$name" ]]; then name="$host"; git config --global user.name "$name" || return 1; fi
    if [[ -z "$email" ]]; then
        [[ "$host" == *.* ]] || host="$host.local"
        email="$login@$host"
        git config --global user.email "$email" || return 1
    fi
    [[ "$(git config --global user.name)" == "$name" && "$(git config --global user.email)" == "$email" ]] || return 1
    git --version
    printf 'Git identity: %s <%s>. Existing credentials/signing preserved.\n' "$name" "$email"
}

prepare_tasks() {
    local i file
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 && -n ${PATHS[$i]} ]] || continue
        file="$WORK/task-$i.${PATHS[$i]##*.}"
        fetch "$BASE_URL/${PATHS[$i]}" "$file" || return 1
        if [[ "$file" == *.py ]]; then
            command -v python3 >/dev/null 2>&1 || { echo 'Python3 is required for offboarding; install it before running this option.'; return 1; }
            python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$file" || return 1
        else /bin/bash -n "$file" || return 1; fi
    done
}

prepare_antigravity_deps() {
    local base packages=(python3 libnss3 libgbm1 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2)
    sudo apt-get update -qq || return 1
    # Ubuntu 24+ renamed these runtime packages for the time64 transition.
    for base in libgtk-3-0 libasound2 libcups2; do
        if apt-cache show "${base}t64" >/dev/null 2>&1; then packages+=("${base}t64")
        else packages+=("$base"); fi
    done
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-remove "${packages[@]}"
}

run_task() {
    local i="$1" rc
    case "$i" in
        3) setup_git; rc=$? ;;
        12) sudo python3 "$WORK/task-$i.py" --keep "$(id -un)"; rc=$? ;;
        5|6) /bin/bash "$WORK/task-$i.sh" "${ARGS[$i]}"; rc=$? ;;
        7) prepare_antigravity_deps && /bin/bash "$WORK/task-$i.sh" "${ARGS[$i]}"; rc=$? ;;
        *)
            # Do not inherit the menu's private-file umask into system installs.
            sudo /bin/bash -c 'umask 022; exec /bin/bash "$@"' bash "$WORK/task-$i.sh"; rc=$? ;;
    esac
    case "$rc" in
        0) RESULTS[$i]=Done; return 0 ;;
        233) RESULTS[$i]='Warning - check output'; return 2 ;;
        *) RESULTS[$i]="Failed (exit $rc)"; return 1 ;;
    esac
}

launch_app() {
    local command
    [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || return 0
    case "$1" in
        0) command -v flatpak >/dev/null 2>&1 || return 1
           nohup flatpak run com.google.Chrome >>"$LOG_DIR/apps.log" 2>&1 </dev/null & ;;
        4) command -v flatpak >/dev/null 2>&1 || return 1
           nohup flatpak run com.slack.Slack >>"$LOG_DIR/apps.log" 2>&1 </dev/null & ;;
        7) command -v gtk-launch >/dev/null 2>&1 || return 1
           nohup gtk-launch antigravity >>"$LOG_DIR/apps.log" 2>&1 </dev/null & ;;
        10) command -v mysql-workbench >/dev/null 2>&1 || return 1
            nohup mysql-workbench >>"$LOG_DIR/apps.log" 2>&1 </dev/null & ;;
        *) return 0 ;;
    esac
    return 0
}

run_selected() {
    local i rc failed=0 count=0 summary='' title='Linux setup finished'
    local ready=()
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 ]] || continue
        count=$((count + 1))
        printf '\n===== %s =====\n' "${NAMES[$i]}"
        run_task "$i"; rc=$?
        if [[ $rc != 0 ]]; then failed=1
        elif [[ $i == 0 || $i == 4 || $i == 7 || $i == 10 ]]; then ready+=("$i"); fi
        printf '%s: %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" | tee -a "$LOG_FILE"
    done
    for i in ${ready[@]+"${ready[@]}"}; do
        if [[ -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
            RESULTS[$i]='Installed - no desktop session to launch'
        elif launch_app "$i"; then RESULTS[$i]='Installed - launch requested'
        else RESULTS[$i]='Installed - launch request failed'; failed=1; fi
        printf '%s: %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" | tee -a "$LOG_FILE"
    done
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} != 1 ]] || summary+="${NAMES[$i]}: ${RESULTS[$i]}"$'\n'
    done
    [[ $failed == 0 ]] || title='Linux setup finished with warnings or failures'
    [[ $count != 0 ]] || title='No tasks selected'
    finish_popup "$title" "${summary}"$'\n'"Screen-lock policy needs a new login. AI/Slack/Twingate sign-in remains manual."$'\n'"Log: $LOG_FILE"
    return "$failed"
}

menu() {
    local cursor=0 i mark key rest
    while true; do
        printf '\033[2J\033[HUbuntu onboarding\n\n'
        for ((i=0; i<${#NAMES[@]}; i++)); do
            mark=' '; [[ ${SELECTED[$i]:-0} != 1 ]] || mark=x
            [[ $i == "$cursor" ]] && printf '> ' || printf '  '
            printf '[%s] %2s. %-25s %s\n' "$mark" "$((i+1))" "${NAMES[$i]}" "${RESULTS[$i]}"
        done
        printf '\nUp/Down + Space: select | 1-9/0: toggle 1-10 | a: all except offboarding\nEnter/r: run selected in order | q: quit\n'
        IFS= read -rsn1 key || return 0
        case "$key" in
            $'\033') rest=''; IFS= read -rsn2 -t 1 rest || true
                case "$rest" in
                    '[A') cursor=$(((cursor+${#NAMES[@]}-1)%${#NAMES[@]})) ;;
                    '[B') cursor=$(((cursor+1)%${#NAMES[@]})) ;;
                esac ;;
            ' ') toggle "$cursor" ;;
            [1-9]) toggle "$((key-1))" ;;
            0) toggle 9 ;;
            a|A) select_all ;;
            ''|r|R)
                if prepare_tasks && sudo -v; then run_selected
                else finish_popup 'Not started' 'Download or administrator authentication failed; queue not run.'; fi
                printf '\nPress any key to return...'; IFS= read -rsn1 key || return 0 ;;
            q|Q) return 0 ;;
        esac
    done
}

main() {
    [[ "$(uname -s)" == Linux ]] || { echo 'This menu requires Ubuntu Linux.'; return 1; }
    [[ $EUID != 0 ]] || { echo 'Run with bash as the desktop user, NOT sudo.'; return 1; }
    local ID VERSION_ID major
    . /etc/os-release || return 1
    major=${VERSION_ID%%.*}
    [[ "$ID" == ubuntu && "$major" =~ ^[0-9]+$ && "$major" -ge 22 ]] || { echo 'Supported: Ubuntu 22.04+; screen-lock policy requires GNOME.'; return 1; }
    command -v curl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 || { echo 'Install curl and sudo first.'; return 1; }
    export PATH="$HOME/.local/bin:$PATH"
    exec </dev/tty >/dev/tty 2>&1 || return 1
    umask 077
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/helfy-onboarding.XXXXXX") || return 1
    trap 'rm -rf "$WORK"' EXIT
    LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/helfy-onboarding"
    mkdir -p "$LOG_DIR" || return 1
    LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG_FILE"
    menu
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
