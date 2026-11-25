#!/bin/bash
# =============================================================================
# Remediate_Power_mac.sh - Stay awake on the charger (macOS)
# =============================================================================
#
# SYNOPSIS:
#     macOS counterpart of Windows Remediate_Hibernate_LidClose.ps1 ("machine
#     stays awake while plugged in"). On AC power only:
#       sleep 0 (never system-sleep), displaysleep 15, womp 1 (wake for network)
#     Battery settings are left at Apple defaults. The 15-minute screen LOCK is a
#     separate task (Remediate_ScreenLock_Timeout_mac.sh) and still applies.
#     macOS always sleeps on lid close unless an external display is attached
#     (clamshell) - that is hardware behaviour and is not changed here.
#
# EXIT CODES:
#     0    = applied and verified
#     1002 = CRITICAL (not root or verification failed)
#
# EXECUTION:
#     sudo bash Remediate_Power_mac.sh
# =============================================================================

set -o pipefail
readonly EXIT_CRITICAL=1002

[[ $EUID -eq 0 ]] || { echo "CRITICAL: Root privileges required"; exit "$EXIT_CRITICAL"; }

/usr/bin/pmset -c sleep 0 displaysleep 15 womp 1 || { echo "CRITICAL: pmset failed"; exit "$EXIT_CRITICAL"; }

# pmset -g custom: section "AC Power:" (laptops) or a single section (desktops).
ac=$(/usr/bin/pmset -g custom | awk '/^AC Power:/{f=1;next} /^[A-Za-z].*Power:/{f=0} f')
[[ -n "$ac" ]] || ac=$(/usr/bin/pmset -g custom)
get() { awk -v k="$1" '$1==k{print $2; exit}' <<<"$ac"; }

if [[ "$(get sleep)" == 0 && "$(get displaysleep)" == 15 ]]; then
    echo "OK: on charger - system sleep off, display sleep 15 min, wake for network on"
    exit 0
fi
echo "CRITICAL: verification failed (sleep=$(get sleep) displaysleep=$(get displaysleep))"
exit "$EXIT_CRITICAL"
