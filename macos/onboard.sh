#!/bin/bash
# onboard.sh - one-line macOS onboarding entry point (counterpart of the Windows `irm | iex`).
#
#   curl -fsSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/onboard.sh | bash
#   ... | bash -s -- --auto --name IA-123      (no menu: run the default selection)
#
# Run as the signed-in user, NOT with sudo. Steps:
#   1. wait for internet (Wi-Fi / captive portal) - up to 5 min
#   2. fix a wrong clock (TLS to GitHub fails when the clock is far off)
#   3. pin the run to ONE commit and download the whole repo as one tarball
#      (no raw CDN lag, no mixed old/new scripts); per-file raw is the fallback
#   4. syntax-check the menu and start it (it checks each selected task before running)
# The whole file is one function called on the last line, so a cut-off
# download can never run half a script.

onboard_main() {
    set -o pipefail
    local repo="${ONBOARD_REPO:-nirli-439/n-sight_scripts}" ref="${ONBOARD_REF:-main}"
    local work sha="" tarball src rc i ok

    say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
    err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
    get() {   # get URL OUT - retries with backoff; tolerates flaky Wi-Fi
        local n
        for n in 1 2 3 4 5; do
            curl --proto '=https,file' -fsSL --connect-timeout 20 --max-time 600 "$1" -o "$2" && [[ -s "$2" ]] && return 0
            sleep $((n * 3))
        done
        return 1
    }

    [[ "$(uname -s)" == Darwin ]] || { err 'macOS only.'; return 1; }
    [[ $EUID != 0 ]] || { err 'Run as the signed-in user, NOT with sudo (it asks for the password itself).'; return 1; }
    local tty="${ONBOARD_TTY:-/dev/tty}"   # override only for automated tests
    [[ -r "$tty" ]] || { err 'No terminal (/dev/tty). Run it from Terminal.app.'; return 1; }

    # 1. Internet.
    if [[ -z "${ONBOARD_TARBALL_URL:-}" ]]; then
        say 'Checking internet...'
        ok=0
        for i in $(seq 1 60); do
            if curl -fsS -o /dev/null --connect-timeout 5 --max-time 10 https://github.com 2>/dev/null; then ok=1; break; fi
            # TLS can fail on a wrong clock while plain HTTP works - step 2 handles that.
            if curl -fsS -o /dev/null --max-time 10 http://captive.apple.com 2>/dev/null; then ok=1; break; fi
            [[ $i == 1 ]] && echo '   No internet yet - connect Wi-Fi (and accept any captive portal). Waiting up to 5 min...'
            sleep 5
        done
        [[ $ok == 1 ]] || { err 'No internet after 5 minutes.'; return 1; }

        # 2. Clock (plain-HTTP Date header works even when TLS does not).
        local hdr remote now skew
        hdr=$(curl -sI --max-time 10 http://captive.apple.com 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
        remote=$(LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$hdr" +%s 2>/dev/null || true)
        now=$(date -u +%s)
        if [[ -n "$remote" ]]; then
            skew=$((now - remote)); skew=${skew#-}
            if [[ $skew -gt 300 ]]; then
                say "Clock is off by ${skew}s - syncing with time.apple.com (admin password)..."
                sudo /usr/bin/sntp -sS time.apple.com </dev/tty >/dev/null 2>&1 \
                    || sudo /usr/sbin/systemsetup -setusingnetworktime on </dev/tty >/dev/null 2>&1 \
                    || err 'Could not fix the clock - set Date & Time to automatic and run again.'
            fi
        fi
    fi

    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/helfy-onboard.XXXXXX") || return 1
    trap 'rm -rf "$work"' EXIT
    src="$work/src"; mkdir -p "$src"

    # 3. One commit, one tarball. GitHub API (60/h per IP) only resolves the SHA; if it is
    #    rate-limited we fall back to the branch tarball, which is still a single snapshot.
    if [[ -n "${ONBOARD_TARBALL_URL:-}" ]]; then
        tarball="$ONBOARD_TARBALL_URL"
    else
        sha=$(curl -fsS --max-time 15 -H 'Accept: application/vnd.github.sha' \
            "https://api.github.com/repos/$repo/commits/$ref" 2>/dev/null || true)
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || sha=""
        tarball="https://codeload.github.com/$repo/tar.gz/${sha:-$ref}"
    fi
    say "Downloading onboarding scripts (${sha:0:7}${sha:+ }from $repo)..."
    if get "$tarball" "$work/repo.tgz" && tar -xzf "$work/repo.tgz" -C "$src" --strip-components 1 2>/dev/null \
        && [[ -f "$src/macos/tools/Onboarding_Menu_mac.sh" ]]; then
        export ONBOARD_SRC="$src"
    else
        # Fallback: menu alone; it fetches each task from raw.githubusercontent itself.
        err 'Tarball download failed - falling back to per-file download.'
        rm -rf "$src"; mkdir -p "$src/macos/tools"
        get "https://raw.githubusercontent.com/$repo/${sha:-$ref}/macos/tools/Onboarding_Menu_mac.sh?t=$(date +%s)" \
            "$src/macos/tools/Onboarding_Menu_mac.sh" || { err 'Cannot download the onboarding menu. Check internet / GitHub access.'; return 1; }
        unset ONBOARD_SRC
        export NSIGHT_SCRIPTS_REPO_BASE="https://raw.githubusercontent.com/$repo/${sha:-$ref}"
    fi

    # 4. Syntax-check the menu; it checks every SELECTED task itself before running any
    #    (an unrelated broken script in the repo must not block onboarding).
    /bin/bash -n "$src/macos/tools/Onboarding_Menu_mac.sh" || { err 'Syntax error in the onboarding menu.'; return 1; }
    export ONBOARD_REV="${sha:-$ref}"

    /bin/bash "$src/macos/tools/Onboarding_Menu_mac.sh" "$@" <"$tty"
    rc=$?
    return $rc
}

onboard_main "$@"; exit $?
