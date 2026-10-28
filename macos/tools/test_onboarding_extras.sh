#!/bin/bash
# Safe: no installs, no sudo, Git writes only an isolated temporary config.
set -euo pipefail
cd "$(dirname "$0")"
source ./Onboarding_Menu_mac.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/onboarding-extras.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
(
    calls=''
    install_desktop() { calls="$calls $1"; }
    sudo() { echo 'FAIL: desktop installs ran as root'; exit 1; }
    for i in 8 9 10 12; do run_task "$i"; done
    [[ "$calls" == ' claude chatgpt google-gemini 1password' ]]
)
(
    WORK="$TMP"
    SELECTED=(0 0 0 0 0 0 0 0 1 1 1 1 1)
    fetch() { printf '#!/bin/bash\n' > "$2"; }
    prepare_tasks
    [[ -f "$WORK/homebrew-path.sh" ]]
)
# Unsupported casks must never reach Homebrew.
install_homebrew() { echo 'FAIL: unexpected Homebrew action'; return 99; }
if install_desktop gemini; then exit 1; fi
(
    export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
    install_homebrew() { :; }
    fake_brew() { [[ "$1" != --prefix ]] || printf '/usr\n'; }
    resolve_brew() { echo fake_brew; }
    hostname() { echo test-mac; }
    id() { echo technician; }
    setup_git </dev/null
    [[ $(/usr/bin/git config --global user.name) == test-mac ]]
    [[ $(/usr/bin/git config --global user.email) == technician@test-mac.local ]]
    [[ $(/usr/bin/git config --global credential.helper) == osxkeychain ]]
    /usr/bin/git config --global credential.helper custom-helper
    /usr/bin/git config --global user.name 'Existing Person'
    /usr/bin/git config --global user.email person@example.com
    setup_git </dev/null
    [[ $(/usr/bin/git config --global credential.helper) == custom-helper ]]
    [[ $(/usr/bin/git config --global user.name) == 'Existing Person' ]]
    [[ $(/usr/bin/git config --global user.email) == person@example.com ]]
    hostname() { echo 'invalid host'; }
    if setup_git </dev/null; then exit 1; fi
    [[ $(/usr/bin/git config --global user.name) == 'Existing Person' ]]
)
echo 'PASS: app routing, correct Google Gemini cask, Git identity, Keychain default, preserved credentials and invalid-input guard'
