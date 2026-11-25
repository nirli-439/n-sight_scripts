#!/bin/bash
# Onboarding_Menu_mac.sh - interactive macOS technician menu (counterpart of
# windows/tools/Onboarding_Menu_windows.ps1). Bash 3.2; no Homebrew/TUI dependency.
#
# Normal start (one line, as the signed-in user, NOT sudo):
#   curl -fsSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/onboard.sh | bash
# onboard.sh downloads the whole repo at one commit and sets ONBOARD_SRC; this
# menu then copies tasks from there. Run standalone, it fetches each task from
# raw.githubusercontent (cache-busted) instead.
#
# Options: --auto (no menu, run the default selection)  --name IA-123
#
# Flow: choose -> ALL questions asked up front (computer name, agent ZIP, ADMIN,
# REMOVE) -> one sudo prompt (kept alive) -> every task staged + syntax-checked ->
# tasks run one at a time with a timeout, Mac kept awake -> apps opened as the
# technician -> final checks + one summary dialog. Log: ~/Library/Logs/Helfy/.
set -o pipefail
BASE_URL="${NSIGHT_SCRIPTS_REPO_BASE:-https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main}"
BASE_URL="${BASE_URL%/}"

# Order follows the Windows USB rules: computer name BEFORE the agent (N-sight
# registers the name), Bitdefender AFTER the agent, tweaks last, removal never by default.
NAMES=('Create admin mac' 'Computer name (IA-xxx)' 'N-sight agent' 'Bitdefender' 'Google Chrome' 'Chrome default browser' 'Google Drive' 'Slack' 'Twingate' 'Homebrew' 'Claude Desktop' 'ChatGPT Desktop' 'Gemini Desktop' 'Claude Code (CLI)' 'Git setup' '1Password' 'NirTab' 'Mac settings' 'Power on charger' 'Screen lock 15 min' 'Pin apps to Dock' 'Remove N-sight agent')
PATHS=('tools/Create_Admin_User_mac.sh' 'tasks/Rename_Hostname_mac.sh' 'tasks/Install_NSight_Agent_mac.sh' 'tasks/Install_BitdefenderAgent_mac.sh' 'tasks/Install_Chrome_mac.sh' '' 'tasks/Install_GoogleDrive_mac.sh' 'tasks/Install_Slack_mac.sh' '' '' '' '' '' '' '' '' 'tasks/Install_NirTab_mac.sh' 'tasks/Configure_Mac_Defaults_mac.sh' 'tasks/Remediate_Power_mac.sh' 'tasks/Remediate_ScreenLock_Timeout_mac.sh' '' 'tasks/Remove_NSight_Agent_mac.sh')
SELECTED=(1 1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 1 1 1 1 0 0)
# Seconds before a hung task is killed and the queue moves on (0 = interactive, no limit).
TIMEOUTS=(0 120 900 1200 900 150 900 900 900 2400 1200 1200 1200 900 900 1200 600 300 60 60 60 300)
# GUI apps opened after the whole queue (empty = agent/CLI/settings task).
APPS=('' '' '' '' '/Applications/Google Chrome.app' '' '/Applications/Google Drive.app' '/Applications/Slack.app' '/Applications/Twingate.app' '' '/Applications/Claude.app' '/Applications/ChatGPT.app' '/Applications/Gemini.app' '' '' '/Applications/1Password.app' '/Applications/NirTab.app' '' '' '' '' '')
I_ADMIN=0 I_NAME=1 I_AGENT=2 I_BREW=9 I_NIRTAB=16 I_REMOVE=21
RESULTS=()
for ((_i=0; _i<${#NAMES[@]}; _i++)); do
    if [[ ${SELECTED[$_i]} == 1 ]]; then RESULTS[$_i]='Ready'; else RESULTS[$_i]='Optional'; fi
done
unset _i
NEW_NAME='' AGENT_PKG='' AUTO=0 KEEPALIVE_PID='' CAFFEINATE_PID='' CURRENT_PID=''

launch_app() {
    [[ -d "$1" && ! -L "$1" ]] || return 1
    # Absolute app path opens the installed copy as this technician, never as root.
    open -a "$1"
}

toggle() { SELECTED[$1]=$((1 - SELECTED[$1])); }

popup() {
    # Arguments, not interpolated AppleScript: app names/messages cannot inject code.
    /usr/bin/osascript -e 'on run argv' \
        -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon note giving up after 120' \
        -e 'end run' -- "$1" "$2" >/dev/null 2>&1 || true
}

confirm_remove() {
    local answer
    printf '\nWARNING: Removing N-sight disconnects monitoring. Take Control is preserved.\nType REMOVE to confirm: '
    IFS= read -r answer || return 1
    [[ "$answer" == REMOVE ]]
}

CURL_RETRY=(--retry 5 --retry-delay 3 --retry-connrefused)
curl --help all 2>/dev/null | grep -q -- --retry-all-errors && CURL_RETRY+=(--retry-all-errors)

fetch() {
    # Cache-buster: raw.githubusercontent CDN lags minutes behind a push ("still old" runs).
    local sep='?'; [[ "$1" == *\?* ]] && sep='&'
    curl --proto '=https' --tlsv1.2 -fSL "${CURL_RETRY[@]}" --connect-timeout 30 --max-time 600 \
        "$1${sep}t=$(date +%s)" -o "$2" && [[ -s "$2" ]]
}

# Copy a repo file from the onboard.sh snapshot, else download it.
stage_file() {
    if [[ -n "${ONBOARD_SRC:-}" ]]; then
        [[ -f "$ONBOARD_SRC/macos/$1" ]] && cp "$ONBOARD_SRC/macos/$1" "$2"
    else
        fetch "$BASE_URL/macos/$1" "$2"
    fi
}

# ---------------------------------------------------------------- user-level tasks
resolve_brew() {
    local brew
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew" ]]; then printf '%s\n' "$brew"; return 0; fi
    done
    return 1
}

install_homebrew() {
    local brew
    if brew=$(resolve_brew); then "$brew" --version; return $?; fi
    fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$WORK/brew.sh" || return 1
    # Run as the technician, never root. NONINTERACTIVE uses the cached sudo ticket
    # (kept alive by the menu) and installs the Command Line Tools without dialogs.
    NONINTERACTIVE=1 /bin/bash "$WORK/brew.sh" || return 1
    brew=$(resolve_brew) || return 1
    "$brew" --version || return 1
    sudo /bin/bash "$WORK/homebrew-path.sh"
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

install_desktop() {
    local cask="$1" app brew
    case "$cask" in
        claude) app=Claude ;;
        chatgpt) app=ChatGPT ;;
        google-gemini) app=Gemini ;;
        1password) app=1Password ;;
        *) echo 'Unsupported desktop app'; return 1 ;;
    esac
    # Already installed (e.g. by the user) and valid: nothing to do.
    if [[ -d "/Applications/$app.app" ]] && /usr/bin/codesign --verify --deep --strict "/Applications/$app.app" 2>/dev/null; then
        echo "$app already installed"; return 0
    fi
    # Official vendor packages via reviewed Homebrew casks; never sudo brew.
    install_homebrew || return 1
    brew=$(resolve_brew) || return 1
    if ! "$brew" list --cask "$cask" >/dev/null 2>&1; then
        HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install --cask --adopt --appdir=/Applications "$cask" \
            || "$brew" install --cask --adopt --appdir=/Applications "$cask" || return 1
    fi
    [[ -d "/Applications/$app.app" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "/Applications/$app.app" || return 1
    /usr/sbin/spctl --assess --type execute "/Applications/$app.app"
}

install_claude_code() {
    local bin="$HOME/.local/bin/claude"
    if [[ -x "$bin" ]]; then "$bin" --version; return $?; fi
    # Anthropic's official native installer, run as the technician (no sudo).
    fetch https://claude.ai/install.sh "$WORK/claude-install.sh" || return 1
    /bin/bash -n "$WORK/claude-install.sh" || return 1
    /bin/bash "$WORK/claude-install.sh" || return 1
    [[ -x "$bin" ]] && "$bin" --version
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

ls_handlers() { /usr/bin/defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null; }
chrome_is_default() {
    ls_handlers | tr -d ' \n' | grep -qi 'LSHandlerRoleAll="com.google.chrome";LSHandlerURLScheme=https;'
}

set_chrome_default() {
    local app='/Applications/Google Chrome.app' i
    [[ -d "$app" ]] || { echo 'Chrome is not installed.'; return 1; }
    if chrome_is_default; then echo 'Chrome is already the default browser.'; return 0; fi
    # macOS always asks the user to confirm; this only triggers that dialog.
    echo '>>> macOS asks "Do you want to change your default web browser?" - click "Use Google Chrome".'
    /usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreServices");' \
        -e '$.LSSetDefaultHandlerForURLScheme($("http"), $("com.google.chrome"));' \
        -e '$.LSSetDefaultHandlerForURLScheme($("https"), $("com.google.chrome"));' >/dev/null 2>&1 \
        || "$app/Contents/MacOS/Google Chrome" --make-default-browser --no-first-run >/dev/null 2>&1 &
    for ((i=0; i<60; i++)); do
        sleep 2
        if chrome_is_default; then echo 'Chrome is now the default browser.'; return 0; fi
    done
    echo 'Not confirmed - open Chrome > Settings > Default browser > Make default.'
    return 233
}

pin_dock() {
    # As the technician (the Dock owner), never root: root-written Dock plists broke Docks before.
    local plist="$HOME/Library/Preferences/com.apple.dock.plist" current app enc added=0
    local list=('/Applications/Google Chrome.app' '/Applications/Slack.app' '/Applications/Claude.app' '/Applications/ChatGPT.app' '/Applications/Gemini.app')
    [[ -f "$plist" ]] && cp -p "$plist" "$plist.helfy-backup-$(date +%Y%m%d%H%M%S)"
    current=$(/usr/bin/defaults read com.apple.dock persistent-apps 2>/dev/null || true)
    for app in "${list[@]}"; do
        [[ -d "$app" ]] || continue
        enc=${app// /%20}
        if [[ "$current" == *"file://$enc/"* ]]; then echo "Already in Dock: ${app##*/}"; continue; fi
        /usr/bin/defaults write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$enc/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>" || return 1
        echo "Pinned: ${app##*/}"; added=$((added + 1))
    done
    [[ $added == 0 ]] || /usr/bin/killall Dock 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------- runner
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
    /usr/bin/sudo -n kill -TERM "$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
}

# run_timed SECONDS CMD... : output to screen + log, stdin closed (a prompt fails
# instead of hanging), killed with its whole process tree after SECONDS.
run_timed() {
    local secs="$1" mark="$WORK/timed-out" pid watcher='' rc
    shift
    rm -f "$mark"
    "$@" </dev/null > >(tee -a "$LOG_FILE") 2>&1 &
    pid=$!
    CURRENT_PID=$pid
    if [[ $secs -gt 0 ]]; then
        ( sleep "$secs"; : > "$mark"; kill_tree "$pid" ) &
        watcher=$!
    fi
    wait "$pid" && rc=0 || rc=$?
    CURRENT_PID=''
    if [[ -n "$watcher" ]]; then
        pkill -P "$watcher" 2>/dev/null || true
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    fi
    if [[ -f "$mark" ]]; then rm -f "$mark"; return 124; fi
    return "$rc"
}

run_task() {
    local index="$1" rc t="${TIMEOUTS[$1]:-900}" task="$WORK/task-$1.sh"
    case "$index" in
        "$I_ADMIN") sudo /bin/bash "$task"; rc=$? ;;   # interactive: prompts stay in Terminal, not logged
        "$I_NAME")  run_timed "$t" sudo /bin/bash "$task" "$NEW_NAME"; rc=$? ;;
        "$I_AGENT") echo "Using package: $AGENT_PKG"; run_timed "$t" sudo /bin/bash "$task" "$AGENT_PKG"; rc=$? ;;
        5)  run_timed "$t" set_chrome_default; rc=$? ;;
        8)  run_timed "$t" install_twingate; rc=$? ;;
        9)  run_timed "$t" install_homebrew; rc=$? ;;
        10) run_timed "$t" install_desktop claude; rc=$? ;;
        11) run_timed "$t" install_desktop chatgpt; rc=$? ;;
        12) run_timed "$t" install_desktop google-gemini; rc=$? ;;
        13) run_timed "$t" install_claude_code; rc=$? ;;
        14) run_timed "$t" setup_git; rc=$? ;;
        15) run_timed "$t" install_desktop 1password; rc=$? ;;
        20) run_timed "$t" pin_dock; rc=$? ;;
        "$I_REMOVE") run_timed "$t" sudo /bin/bash "$task" --no-popup; rc=$? ;;
        *)  run_timed "$t" sudo /bin/bash "$task"; rc=$? ;;
    esac
    # POSIX shell exit statuses wrap modulo 256: 1001 -> 233; 1002 -> 234.
    case "$rc" in
        0)
            RESULTS[$index]='Done'
            [[ $index != "$I_NIRTAB" ]] || RESULTS[$index]='Installed - open app and approve permissions'
            return 0 ;;
        233) RESULTS[$index]='Warning - check output'; return 2 ;;
        124) RESULTS[$index]="Timed out after ${t}s"; return 1 ;;
        *) RESULTS[$index]="Failed (exit $rc)"; return 1 ;;
    esac
}

final_checks() {
    # Same idea as the Windows USB "Final checks": what is actually on the Mac now.
    local name ok=1 i
    name=$(scutil --get ComputerName 2>/dev/null)
    if [[ "$name" =~ ^IA-[0-9]+$ ]]; then echo "OK   Computer name $name"; else echo "--   Computer name '$name' is not an IA-xxx asset key"; ok=0; fi
    if pgrep -x rmmagentd >/dev/null 2>&1; then echo 'OK   N-sight agent running'; else echo '--   N-sight agent not running'; ok=0; fi
    if pgrep -qf BDLDaemon 2>/dev/null; then echo 'OK   Bitdefender running'; else echo '--   Bitdefender not running'; ok=0; fi
    if fdesetup status 2>/dev/null | grep -q 'On'; then echo 'OK   FileVault on'; else echo '--   FileVault off (GravityZone policy / user)'; fi
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 && -n ${APPS[$i]} ]] || continue
        if [[ -d ${APPS[$i]} ]]; then echo "OK   ${NAMES[$i]}"; else echo "--   ${NAMES[$i]} missing"; ok=0; fi
    done
    [[ $ok == 1 ]]
}

run_selected() {
    local i rc failed=0 count=0 summary='' title='Setup finished' checks=''
    local ready=()
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 ]] || continue
        count=$((count + 1))
        printf '\n===== [%s] %s =====\n' "$count" "${NAMES[$i]}" | tee -a "$LOG_FILE"
        run_task "$i"; rc=$?
        if [[ $rc != 0 ]]; then
            failed=1
        elif [[ -n ${APPS[$i]} ]]; then
            ready+=("$i")
        fi
        printf '%s: %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" | tee -a "$LOG_FILE"
    done
    # Launch only this run's successful GUI selections, after ALL installers.
    for i in ${ready[@]+"${ready[@]}"}; do
        if launch_app "${APPS[$i]}"; then
            RESULTS[$i]='Installed - launch requested'
            [[ $i != "$I_NIRTAB" ]] || RESULTS[$i]='Launch requested - check menu bar/approve permissions'
        else
            RESULTS[$i]='Installed - launch failed; open manually'
            failed=1
        fi
        printf '%s: %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" | tee -a "$LOG_FILE"
    done
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} != 1 && ${RESULTS[$i]} != Cancelled* && ${RESULTS[$i]} != Skipped* ]] || summary+="${NAMES[$i]}: ${RESULTS[$i]}"$'\n'
    done
    if [[ $count != 0 ]]; then
        checks=$(final_checks)
        printf '\nFinal checks:\n%s\n' "$checks" | tee -a "$LOG_FILE"
    fi
    printf '\nFinished %s selected task(s). Log: %s\n' "$count" "$LOG_FILE"
    [[ $failed == 0 ]] || title='Setup finished with warnings or failures'
    [[ $count != 0 ]] || title='No tasks run'
    popup "$title" "${summary:-No tasks selected.}${checks:+$'\n'Final checks:$'\n'$checks}"$'\n'"Log: $LOG_FILE"
    return "$failed"
}

serial_number() {
    ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# Newest N-sight Mac agent in ~/Downloads: .ZIP/.zip/.pkg in any letter case, or the
# folder Safari makes when it auto-unzips (zipped back so the installer gets a file).
find_agent_pkg() {
    local f
    f=$(ls -td "$HOME"/Downloads/[Oo][Ss][Xx]_[Aa][Gg][Ee][Nn][Tt]* 2>/dev/null | head -1 || true)
    [[ -n "$f" ]] || return 0
    if [[ -d "$f" ]]; then
        [[ -n "$(find "$f" -maxdepth 3 -name '*.pkg' 2>/dev/null | head -1)" ]] || return 0
        /usr/bin/ditto -c -k --keepParent "$f" "$f.ZIP" 2>/dev/null || return 0
        f="$f.ZIP"
    fi
    printf '%s\n' "$f"
}

# Company Mac agent (site ISRAEL HELFY OFFICE) in Drive folder "agents-nsight", shared by link.
# To update: in Drive, right-click the ZIP > File information > Manage versions > upload the new
# ZIP (keeps this ID). Override per run: NSIGHT_AGENT_URL=<url>.
AGENT_URL="${NSIGHT_AGENT_URL:-https://drive.usercontent.google.com/download?id=1OhjyAdqQUM4DxE8g-pXkhTxoJGmcYUWL&export=download&confirm=t}"

download_agent_pkg() {
    local dest="$HOME/Downloads/OSX_AGENT_HELFY_RW.ZIP" tmp
    mkdir -p "$HOME/Downloads" || return 1
    tmp="$dest.part"
    echo 'Downloading the N-sight Mac agent from Google Drive...'
    curl -fsSL "${CURL_RETRY[@]}" --connect-timeout 30 --max-time 900 -o "$tmp" "$AGENT_URL" || { rm -f "$tmp"; return 1; }
    # Must be a real agent package, not a Drive HTML error/consent page.
    if /usr/bin/unzip -l "$tmp" 2>/dev/null | grep -qi 'install\.pkg'; then
        mv -f "$tmp" "$dest" && printf '%s\n' "$dest"
    else
        rm -f "$tmp"; echo 'Download is not an N-sight agent ZIP (Drive link changed or not shared?).'; return 1
    fi
}

# Every question BEFORE the queue starts, so the technician can walk away after this.
collect_inputs() {
    local answer current
    if [[ ${SELECTED[$I_NAME]} == 1 ]]; then
        current=$(scutil --get ComputerName 2>/dev/null)
        if [[ -z "$NEW_NAME" ]]; then
            printf '\nComputer name = Jira Assets key (N-sight syncs on it).\n'
            printf 'Serial: %s   Current name: %s\n' "$(serial_number)" "$current"
            if [[ "$current" =~ ^IA-[0-9]+$ ]]; then
                read -r -p "Asset key [Enter = keep $current]: " answer || answer=''
            else
                read -r -p 'Asset key, e.g. IA-123 [Enter = skip]: ' answer || answer=''
            fi
            NEW_NAME=$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
            [[ -n "$NEW_NAME" || ! "$current" =~ ^IA-[0-9]+$ ]] || NEW_NAME="$current"
        fi
        if [[ -z "$NEW_NAME" ]]; then
            SELECTED[$I_NAME]=0; RESULTS[$I_NAME]='Skipped - no asset key'
        elif [[ ! "$NEW_NAME" =~ ^IA-[0-9]+$ ]]; then
            echo "'$NEW_NAME' is not IA-<number> - computer name skipped."
            SELECTED[$I_NAME]=0; RESULTS[$I_NAME]='Skipped - invalid asset key'
        fi
    fi
    if [[ ${SELECTED[$I_AGENT]} == 1 ]]; then
        while true; do
            # Dashboard links expire; use the newest RW package the technician downloaded.
            AGENT_PKG=$(find_agent_pkg)
            [[ -z "$AGENT_PKG" ]] || break
            if [[ -z "${AGENT_DL_TRIED:-}" ]]; then
                AGENT_DL_TRIED=1
                AGENT_PKG=$(download_agent_pkg | tail -1)
                [[ "$AGENT_PKG" != */OSX_AGENT_HELFY_RW.ZIP ]] || { echo "Agent package: $AGENT_PKG"; break; }
                AGENT_PKG=''
            fi
            printf '\nNo OSX_AGENT_*_RW.ZIP in ~/Downloads.\nN-sight dashboard > Download Agent > Mac, save to Downloads, then press Enter (s = skip agent): '
            IFS= read -r answer || answer=s   # no terminal input: skip, never loop forever
            if [[ "$answer" == s || "$answer" == S ]]; then
                SELECTED[$I_AGENT]=0; RESULTS[$I_AGENT]='Skipped - no agent package'; break
            fi
        done
    fi
    if [[ ${SELECTED[$I_ADMIN]} == 1 ]]; then
        printf '\nCreate admin uses a predictable date password and grants passwordless sudo.\n'
        printf 'Only continue for a trusted technician account; rotate the password immediately.\n'
        read -r -p 'Type ADMIN to keep it selected (Enter = skip): ' answer || answer=''
        [[ "$answer" == ADMIN ]] || { SELECTED[$I_ADMIN]=0; RESULTS[$I_ADMIN]='Skipped'; }
    fi
    if [[ ${SELECTED[$I_REMOVE]} == 1 ]] && ! confirm_remove; then
        SELECTED[$I_REMOVE]=0; RESULTS[$I_REMOVE]='Cancelled'
    fi
    return 0
}

prepare_tasks() {
    # Stage the complete queue BEFORE any change; a failed download never becomes
    # an empty script reported as successful.
    local i
    for ((i=0; i<${#NAMES[@]}; i++)); do
        [[ ${SELECTED[$i]:-0} == 1 && -n ${PATHS[$i]} ]] || continue
        stage_file "${PATHS[$i]}" "$WORK/task-$i.sh" || { echo "Download failed: ${PATHS[$i]}"; return 1; }
        /bin/bash -n "$WORK/task-$i.sh" || { echo "Syntax error: ${PATHS[$i]}"; return 1; }
    done
    for i in 9 10 11 12 14 15; do
        if [[ ${SELECTED[$i]:-0} == 1 ]]; then
            stage_file tasks/Remediate_Homebrew_Path_mac.sh "$WORK/homebrew-path.sh" || return 1
            break
        fi
    done
}

start_session() {
    # One password prompt; keep the ticket fresh so long installs never stop to ask again.
    sudo -v || return 1
    ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
    KEEPALIVE_PID=$!
    # No sleep (display, idle, disk, system) while this menu runs.
    /usr/bin/caffeinate -dimsu -w "$$" &
    CAFFEINATE_PID=$!
}

run_queue() {
    collect_inputs
    if ! prepare_tasks; then
        popup 'Not started' 'A task could not be downloaded or failed its syntax check. Nothing was changed.'
        return 1
    fi
    if [[ -z "$KEEPALIVE_PID" ]] && ! start_session; then
        popup 'Not started' 'Administrator authentication failed. Nothing was changed.'
        return 1
    fi
    run_selected
}

type_numbers() {
    local line tok k a b
    read -r -p 'Numbers to toggle (e.g. 14 21 or 2-5): ' line
    for tok in ${line//,/ }; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then a=$tok; b=$tok
        else continue; fi
        for ((k=a; k<=b; k++)); do
            [[ $k -ge 1 && $k -le ${#NAMES[@]} ]] && toggle $((k - 1))
        done
    done
}

menu() {
    local cursor=0 i mark key rest
    while true; do
        printf '\033[2J\033[HmacOS onboarding - %s%s\n\n' "$(scutil --get ComputerName 2>/dev/null)" "${ONBOARD_REV:+  (rev ${ONBOARD_REV:0:7})}"
        for ((i=0; i<${#NAMES[@]}; i++)); do
            mark=' '; [[ ${SELECTED[$i]:-0} == 1 ]] && mark=x
            [[ $i == "$cursor" ]] && printf '> ' || printf '  '
            printf '[%s] %2s. %-24s %s\n' "$mark" "$((i + 1))" "${NAMES[$i]}" "${RESULTS[$i]}"
        done
        printf '\nUp/Down: move | Space or 1-9: toggle | t: type numbers | a: all (no removal) | n: none\nEnter: run selected in order | q: quit\n'
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
            t|T) printf '\n'; type_numbers ;;
            a|A) for ((i=0; i<${#NAMES[@]}; i++)); do SELECTED[$i]=1; done; SELECTED[$I_REMOVE]=0 ;;
            n|N) for ((i=0; i<${#NAMES[@]}; i++)); do SELECTED[$i]=0; done ;;
            ''|r|R)
                run_queue
                printf '\nPress any key to return to menu...'; IFS= read -rsn1 key || return 0 ;;
            q|Q) return 0 ;;
        esac
    done
}

cleanup() {
    # Background tasks ignore Ctrl-C (no job control): stop the running one explicitly.
    [[ -z "$CURRENT_PID" ]] || kill_tree "$CURRENT_PID"
    [[ -z "$KEEPALIVE_PID" ]] || kill "$KEEPALIVE_PID" 2>/dev/null
    [[ -z "$CAFFEINATE_PID" ]] || kill "$CAFFEINATE_PID" 2>/dev/null
    rm -rf "$WORK"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) AUTO=1 ;;
            --name) NEW_NAME=$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]'); shift ;;
            --name=*) NEW_NAME=$(printf '%s' "${1#--name=}" | tr '[:lower:]' '[:upper:]') ;;
            -h|--help) sed -n '2,17p' "$0" 2>/dev/null; return 0 ;;
            *) echo "Unknown option: $1"; return 1 ;;
        esac
        shift
    done
    [[ "$(uname -s)" == Darwin ]] || { echo 'macOS only'; return 1; }
    [[ $EUID != 0 ]] || { echo 'Run with bash, NOT sudo. Installers request sudo when needed.'; return 1; }
    exec </dev/tty >/dev/tty 2>&1 || return 1
    umask 077
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/helfy-onboarding.XXXXXX") || return 1
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT TERM
    mkdir -p "$HOME/Library/Logs/Helfy" || return 1
    LOG_FILE="$HOME/Library/Logs/Helfy/onboarding-$(date +%Y%m%d-%H%M%S).log"
    # Admin credentials/passwords are intentionally NOT captured in this log.
    printf 'Onboarding on %s, macOS %s, source %s\n' "$(scutil --get ComputerName 2>/dev/null)" \
        "$(sw_vers -productVersion 2>/dev/null)" "${ONBOARD_SRC:+snapshot }${ONBOARD_REV:-$BASE_URL}" > "$LOG_FILE"
    if [[ $AUTO == 1 ]]; then
        run_queue
        return $?
    fi
    menu
}

# Runs when executed (file or `curl | bash`), not when sourced by the tests.
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then main "$@"; exit $?; fi
