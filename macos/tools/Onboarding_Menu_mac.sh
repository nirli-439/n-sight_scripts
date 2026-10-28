#!/bin/bash
# Interactive macOS technician menu. Bash 3.2; no Homebrew/TUI dependency.
# Download to a file and run with bash (NOT sudo); prompts use /dev/tty.
set -o pipefail
BASE_URL=https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main
NAMES=('Bitdefender' 'Google Chrome' 'Google Drive' 'Slack' 'Create admin mac' 'Homebrew' 'Twingate' 'Remove N-sight agent' 'Claude Desktop' 'ChatGPT Desktop' 'Gemini Desktop' 'Git setup' '1Password' 'NirTab')
PATHS=('tasks/Install_BitdefenderAgent_mac.sh' 'tasks/Install_Chrome_mac.sh' 'tasks/Install_GoogleDrive_mac.sh' 'tasks/Install_Slack_mac.sh' 'tools/Create_Admin_User_mac.sh' '' '' 'tasks/Remove_NSight_Agent_mac.sh' '' '' '' '' '' 'tasks/Install_NirTab_mac.sh')
SELECTED=(1 1 1 1 1 1 1 0 0 0 0 0 0 0)
RESULTS=('Ready' 'Ready' 'Ready' 'Ready' 'Ready' 'Ready' 'Ready' 'Optional' 'Optional' 'Optional' 'Optional' 'Optional' 'Optional' 'Optional')

toggle() { SELECTED[$1]=$((1 - SELECTED[$1])); }

popup() {
    # Arguments, not interpolated AppleScript: app names/messages cannot inject code.
    /usr/bin/osascript -e 'on run argv' \
        -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon note giving up after 30' \
        -e 'end run' -- "$1" "$2" >/dev/null 2>&1 || true
}

confirm_remove() {
    local answer
    printf '\nWARNING: Removing N-sight disconnects monitoring. Take Control is preserved.\nType REMOVE to confirm: '
    IFS= read -r answer
    [[ "$answer" == REMOVE ]]
}

fetch() {
    curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 30 --max-time 180 "$1" -o "$2"
}

install_homebrew() {
    local brew
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew" ]]; then "$brew" --version; return $?; fi
    done
    fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$WORK/brew.sh" || return 1
    # Run as the technician, never root. The official installer handles sudo/CLT.
    /bin/bash "$WORK/brew.sh" || return 1
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew" ]]; then
            "$brew" --version || return 1
            sudo /bin/bash "$WORK/homebrew-path.sh"
            return $?
        fi
    done
    return 1
}

install_twingate() {
    if [[ -d /Applications/Twingate.app ]]; then
        /usr/bin/codesign --verify --deep /Applications/Twingate.app
        return $?
    fi
    # Pinned vendor package + published Homebrew cask hash; independent of Homebrew.
    fetch https://binaries.twingate.com/client/macos/2026.279.29231/Twingate.pkg "$WORK/Twingate.pkg" || return 1
    printf '%s  %s\n' ba97a0208ac7277a0de630b58960bf7b321e044b574f576c0c84d8d9831108d4 "$WORK/Twingate.pkg" | shasum -a 256 -c - || return 1
    /usr/sbin/pkgutil --check-signature "$WORK/Twingate.pkg" || return 1
    sudo /usr/sbin/installer -pkg "$WORK/Twingate.pkg" -target / || return 1
    [[ -d /Applications/Twingate.app ]] && /usr/bin/codesign --verify --deep /Applications/Twingate.app
}

resolve_brew() {
    local brew
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew" ]]; then printf '%s\n' "$brew"; return 0; fi
    done
    return 1
}

install_desktop() {
    local cask="$1" app brew
    case "$cask" in
        claude) app=Claude ;;
        chatgpt) app=ChatGPT ;;
        google-gemini) app=Gemini ;;
        1password) app=1Password ;;
        *) echo 'Unsupported desktop app'; return 1 ;;
    esac
    # Official vendor packages via reviewed Homebrew casks; never sudo brew.
    install_homebrew || return 1
    brew=$(resolve_brew) || return 1
    if ! "$brew" list --cask "$cask" >/dev/null 2>&1; then
        "$brew" install --cask --adopt --appdir=/Applications "$cask" || return 1
    fi
    [[ -d "/Applications/$app.app" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "/Applications/$app.app" || return 1
    /usr/sbin/spctl --assess --type execute "/Applications/$app.app"
}

setup_git() {
    local brew git name email host login helper
    install_homebrew || return 1
    brew=$(resolve_brew) || return 1
    "$brew" list --formula git >/dev/null 2>&1 || "$brew" install git || return 1
    git="$("$brew" --prefix git)/bin/git"
    [[ -x "$git" ]] || return 1
    name=$("$git" config --global user.name 2>/dev/null || true)
    email=$("$git" config --global user.email 2>/dev/null || true)
    host=$(hostname) || return 1
    login=$(id -un) || return 1
    [[ -n "$host" && "$host" != *[!a-zA-Z0-9.-]* && -n "$login" && "$login" != *[!a-zA-Z0-9_.-]* ]] || {
        echo 'Machine hostname/username cannot form a local Git identity.'; return 1;
    }
    # Local machine identity, not an invented company or verified GitHub email.
    if [[ -z "$name" ]]; then
        name="$host"
        "$git" config --global user.name "$name" || return 1
    fi
    if [[ -z "$email" ]]; then
        [[ "$host" == *.* ]] || host="$host.local"
        email="$login@$host"
        "$git" config --global user.email "$email" || return 1
    fi
    helper=$("$git" config --global --get-all credential.helper 2>/dev/null || true)
    [[ -n "$helper" ]] || "$git" config --global credential.helper osxkeychain || return 1
    [[ "$("$git" config --global user.name)" == "$name" && "$("$git" config --global user.email)" == "$email" ]] || return 1
    "$git" --version
    printf 'Git identity: %s <%s>\n' "$name" "$email"
    echo 'Git identity verified. Existing credentials/signing settings preserved; GitHub login is separate.'
}

run_task() {
    local index="$1" rc
    case "$index" in
        4)
            printf '\nExisting admin tool uses a predictable date password and grants passwordless sudo.\n'
            printf 'Only continue for a trusted technician account; rotate the password immediately.\n'
            local answer
            read -r -p 'Type ADMIN to run this tool: ' answer
            [[ "$answer" == ADMIN ]] || return 1
            sudo /bin/bash "$WORK/task-$index.sh"; rc=$? ;;
        5) install_homebrew; rc=$? ;;
        6) install_twingate; rc=$? ;;
        7) sudo /bin/bash "$WORK/task-$index.sh" --no-popup; rc=$? ;;
        8) install_desktop claude; rc=$? ;;
        9) install_desktop chatgpt; rc=$? ;;
        10) install_desktop google-gemini; rc=$? ;;
        11) setup_git; rc=$? ;;
        12) install_desktop 1password; rc=$? ;;
        *) sudo /bin/bash "$WORK/task-$index.sh"; rc=$? ;;
    esac
    # POSIX shell exit statuses wrap modulo 256: 1001 -> 233; 1002 -> 234.
    case "$rc" in
        0)
            RESULTS[$index]='Done'
            [[ $index != 13 ]] || RESULTS[$index]='Installed - open app and approve permissions'
            return 0 ;;
        233) RESULTS[$index]='Warning - check output'; return 2 ;;
        *) RESULTS[$index]="Failed (exit $rc)"; return 1 ;;
    esac
}

run_selected() {
    local i rc failed=0 count=0 summary='' title='Setup finished'
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 ]] || continue
        if [[ $i == 7 ]] && ! confirm_remove; then
            RESULTS[$i]='Cancelled'
        else
            count=$((count + 1))
            printf '\n===== %s =====\n' "${NAMES[$i]}"
            run_task "$i"; rc=$?
            if [[ $rc != 0 ]]; then failed=1; fi
        fi
        printf '%s: %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" | tee -a "$LOG_FILE"
        summary+="${NAMES[$i]}: ${RESULTS[$i]}"$'\n'
    done
    printf '\nFinished %s selected task(s). Log: %s\n' "$count" "$LOG_FILE"
    [[ $failed == 0 ]] || title='Setup finished with warnings or failures'
    [[ $count != 0 ]] || title='No tasks run'
    popup "$title" "${summary:-No tasks selected.}"$'\n'"Log: $LOG_FILE"
    return "$failed"
}

prepare_tasks() {
    # Stage the complete queue BEFORE removal or any installs; failed downloads
    # never become empty bash scripts reported as successful.
    local i
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 && -n ${PATHS[$i]} ]] || continue
        fetch "$BASE_URL/macos/${PATHS[$i]}" "$WORK/task-$i.sh" || return 1
        /bin/bash -n "$WORK/task-$i.sh" || return 1
    done
    if [[ ${SELECTED[5]:-0} == 1 || ${SELECTED[8]:-0} == 1 || ${SELECTED[9]:-0} == 1 || ${SELECTED[10]:-0} == 1 || ${SELECTED[11]:-0} == 1 || ${SELECTED[12]:-0} == 1 ]]; then
        fetch "$BASE_URL/macos/tasks/Remediate_Homebrew_Path_mac.sh" "$WORK/homebrew-path.sh" || return 1
    fi
}

menu() {
    local cursor=0 i mark key rest
    while true; do
        printf '\033[2J\033[HmacOS onboarding\n\n'
        for ((i=0; i<${#NAMES[@]}; i++)); do
            mark=' '; [[ ${SELECTED[$i]:-0} == 1 ]] && mark=x
            [[ $i == "$cursor" ]] && printf '> ' || printf '  '
            printf '[%s] %s. %-23s %s\n' "$mark" "$((i + 1))" "${NAMES[$i]}" "${RESULTS[$i]}"
        done
        printf '\nUp/Down: move | Space or 1-9: toggle | a: select all except removal\nEnter/r: run selected in order | q: quit\n'
        IFS= read -rsn1 key || return 0
        case "$key" in
            $'\033')
                rest=''; IFS= read -rsn2 -t 1 rest || true
                case "$rest" in
                    '[A') cursor=$(((cursor + ${#NAMES[@]} - 1) % ${#NAMES[@]})) ;;
                    '[B') cursor=$(((cursor + 1) % ${#NAMES[@]})) ;;
                esac ;;
            ' ') toggle "$cursor" ;;
            [1-9]) toggle "$((key - 1))" ;;
            a|A) for ((i=0; i<${#NAMES[@]}; i++)); do SELECTED[$i]=1; done; SELECTED[7]=0 ;;
            ''|r|R)
                if prepare_tasks && sudo -v; then
                    run_selected
                else
                    popup 'Not started' 'Download or administrator authentication failed. No queue was run.'
                fi
                printf '\nPress any key to return to menu...'; IFS= read -rsn1 key || return 0 ;;
            q|Q) return 0 ;;
        esac
    done
}

main() {
    [[ "$(uname -s)" == Darwin ]] || { echo 'macOS only'; return 1; }
    [[ $EUID != 0 ]] || { echo 'Run with bash, NOT sudo. Installers request sudo when needed.'; return 1; }
    exec </dev/tty >/dev/tty 2>&1 || return 1
    umask 077
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/helfy-onboarding.XXXXXX") || return 1
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$HOME/Library/Logs/Helfy" || return 1
    LOG_FILE="$HOME/Library/Logs/Helfy/onboarding-$(date +%Y%m%d-%H%M%S).log"
    # Admin credentials/passwords are intentionally NOT captured in this log.
    : > "$LOG_FILE"
    menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
