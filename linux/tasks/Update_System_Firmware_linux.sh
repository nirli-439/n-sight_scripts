#!/bin/bash
# Ubuntu 22.04+ physical desktops/laptops. N-Sight: 0 OK, 1001 warning, 1002 critical.
# No removals, config replacement or automatic reboot. Firmware requires a local operator.
# fwupd upstream CLI/reference: https://fwupd.github.io/libfwupdplugin/fwupdmgr.html
# Ubuntu 22.04 baseline flags/rc: https://github.com/fwupd/fwupd/blob/1.7.5/src/fu-util.c
# rc 2 = nothing to do; newer versions rc 3 = resource not found (NOT up-to-date).
set -uo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export UCF_FORCE_CONFFOLD=1
critical=0
warning=0
warn() { echo "WARNING: $*"; warning=1; }
fail() { echo "CRITICAL: $*"; critical=1; }
[ "$(id -u)" = 0 ] || { echo 'CRITICAL: Root required'; exit 1002; }
[ "$(uname -s)" = Linux ] && [ -r /etc/os-release ] || { echo 'WARNING: Ubuntu 22.04+ required'; exit 1001; }
. /etc/os-release
if [ "${ID:-}" != ubuntu ] || ! [[ "${VERSION_ID:-}" =~ ^([0-9]+)\.([0-9]+)$ ]] || (( 10#${BASH_REMATCH[1]} < 22 || (10#${BASH_REMATCH[1]} == 22 && 10#${BASH_REMATCH[2]} < 4) )); then
    echo 'WARNING: Ubuntu 22.04+ required'; exit 1001
fi
# --no-remove guards both dependency installation and upgrade; holds are never overridden.
apt_options=(-y -qq --no-remove -o Dpkg::Options::=--force-confold)
if apt-get -o APT::Update::Error-Mode=any update -qq; then
    apt-get "${apt_options[@]}" --with-new-pkgs upgrade || fail 'APT upgrade failed; package state may be partial.'
    if [ "$critical" = 0 ] && { ! command -v fwupdmgr >/dev/null || ! command -v python3 >/dev/null; }; then
        apt-get "${apt_options[@]}" install fwupd python3 || fail 'APT firmware prerequisites failed.'
    fi
else
    fail 'APT index refresh failed; upgrade skipped rather than using stale indexes.'
fi
# Report after all APT operations, including prerequisites. Listing is not proof of latest.
echo 'Held packages:'
if held=$(apt-mark showhold); then
    if [ -n "$held" ]; then printf '%s\n' "$held"; warn 'Held packages exist; holds preserved.'; else echo '(none)'; fi
else fail 'Cannot read package holds.'; fi
echo 'Remaining upgradable / kept-back packages (includes phased updates):'
if pending=$(apt list --upgradable 2>/dev/null); then
    printf '%s\n' "$pending"
    if [[ "$pending" == *$'\n'* ]]; then warn 'Packages remain pending; system is NOT fully up-to-date.'; fi
else fail 'Cannot verify remaining package upgrades.'; fi

on_battery() {
    local supply type status battery=0 external=0 online
    for supply in /sys/class/power_supply/*; do
        [ -r "$supply/type" ] || continue
        read -r type < "$supply/type" || true
        if [ "$type" = Battery ]; then
            battery=1
            status=Unknown
            [ ! -r "$supply/status" ] || read -r status < "$supply/status" || true
            [ "$status" != Discharging ] || return 0
        elif [ -r "$supply/online" ]; then
            online=0
            read -r online < "$supply/online" || true
            [ "$online" != 1 ] || external=1
        fi
    done
    # Battery-present machines need positive external-power evidence, not just 'Full'.
    [ "$battery" = 1 ] && [ "$external" != 1 ]
}
firmware() {
    local help devices plan rc confirmation
    command -v fwupdmgr >/dev/null && command -v python3 >/dev/null || { warn 'fwupd/python3 unavailable; firmware skipped.'; return; }
    help=$(fwupdmgr --help) || { warn 'Cannot inspect fwupdmgr capabilities.'; return; }
    for flag in --no-reboot-check --no-unreported-check --no-remote-check --json; do
        [[ "$help" == *"$flag"* ]] || { warn "fwupdmgr lacks $flag; firmware skipped safely."; return; }
    done
    # Uses fwupd's trusted remote signature verification; never enables testing/unsigned modes.
    fwupdmgr --json --no-remote-check enable-remote lvfs </dev/null || { warn 'Cannot enable signed LVFS remote; firmware skipped.'; return; }
    # --force is ONLY for metadata freshness (bypasses the 24-hour cache), NEVER flashing.
    fwupdmgr --no-unreported-check --no-remote-check refresh --force </dev/null || { warn 'Signed firmware metadata refresh failed; no flashing.'; return; }
    devices=$(fwupdmgr --json get-devices </dev/null) || { warn 'Firmware hardware discovery failed/unsupported.'; return; }
    if ! printf '%s' "$devices" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any("supported" in x.get("Flags",[]) and "updatable" in x.get("Flags",[]) for x in d.get("Devices",[])) else 1)'; then
        warn 'No supported updatable hardware detected (or unrecognized fwupd JSON); firmware skipped.'; return
    fi
    if printf '%s' "$devices" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(x.get("UpdateState") in (1,4,"pending","needs-reboot") or "needs-activation" in x.get("Flags",[]) for x in d.get("Devices",[])) else 1)'; then
        warn 'Firmware activation/reboot is pending; no reboot performed.'
        printf '%s\n' "$devices"
    fi
    plan=$(fwupdmgr --no-unreported-check --no-remote-check get-updates </dev/null 2>&1); rc=$?
    printf '%s\n' "$plan"
    case "$rc" in
        0) ;;
        2) echo 'OK: No applicable firmware upgrades from refreshed metadata. This does not cover unsupported devices.'; return ;;
        *) warn "Firmware discovery failed (rc $rc); not a claim of latest firmware."; return ;;
    esac
    echo 'FIRMWARE PLAN: Apply the applicable vendor releases listed above using fwupdmgr update.'
    echo 'Vendor signature, power and safety checks remain enabled. Firmware may require manual reboot/shutdown or physical interaction.'
    on_battery && { warn 'On battery or battery state unknown; firmware flashing skipped.'; return; }
    # /dev/tty cannot be substituted by piped stdin. Opening fails closed on RMM/headless runs.
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then warn 'No controlling terminal; firmware updates remain pending.'; return; fi
    printf '%s\n' "$plan" >&3
    printf 'Type APPLY FIRMWARE to apply this plan (anything else skips): ' >&3
    confirmation=
    IFS= read -r confirmation <&3 || true
    if [ "$confirmation" != 'APPLY FIRMWARE' ]; then exec 3>&-; warn 'Firmware not confirmed; updates remain pending.'; return; fi
    on_battery && { exec 3>&-; warn 'Power changed; firmware skipped.'; return; }
    # No --assume-yes: retain vendor-specific warnings/interactive checks on the terminal.
    fwupdmgr --no-reboot-check --no-unreported-check --no-remote-check update <&3 >&3 2>&3; rc=$?
    exec 3>&-
    case "$rc" in
        0) warn 'Firmware update command completed; activation/reboot/shutdown and hardware verification may still be required. No reboot requested.' ;;
        2) warn 'Firmware update returned nothing-to-do; no successful flash claimed.' ;;
        *) fail "Firmware update failed (rc $rc); review vendor output; firmware state may be partial." ;;
    esac
    fwupdmgr --json get-devices </dev/null || warn 'Cannot read back firmware device/activation status.'
    fwupdmgr --no-unreported-check --no-remote-check get-updates </dev/null
    rc=$?
    case "$rc" in 0) warn 'Firmware updates still pending.' ;; 2) echo 'No further applicable firmware downloads; activation may still be pending.' ;; *) warn "Firmware recheck failed (rc $rc)." ;; esac
}
if [ "$critical" = 0 ]; then firmware
else warn 'Firmware skipped after APT failure; repair the OS package state first.'; fi
if [ -e /run/reboot-required ]; then
    warn 'OS reboot required (/run/reboot-required); reboot NOT performed.'
    [ ! -r /run/reboot-required.pkgs ] || cat /run/reboot-required.pkgs
else
    echo 'OS reboot marker absent; this does not prove firmware activation or running services/kernel are current.'
fi
[ "$critical" = 0 ] || exit 1002
[ "$warning" = 0 ] || exit 1001
echo 'OK: Safe package upgrade and firmware check complete; no pending updates reported by these checks.'
exit 0
