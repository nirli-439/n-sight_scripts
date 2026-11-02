#!/bin/bash
# =============================================================================
# Check_Bitdefender_EDR_mac.sh - Health check for Bitdefender GravityZone (BEST / EDR) on macOS
# =============================================================================
#
# SYNOPSIS:
#     24x7 check that the GravityZone agent is installed, its daemon is running and the
#     Bitdefender system extensions (Endpoint Security + Network) are activated & enabled.
#     Read-only, makes no changes.
#
# DESCRIPTION:
#     1. Installed       - /Library/Bitdefender/AVP/BDLDaemon or "Endpoint Security for Mac.app"
#     2. Daemon running  - BDLDaemon process / com.bitdefender.* LaunchDaemons loaded
#     3. System ext.     - systemextensionsctl: Team ID GUNFMW623Y extensions "[activated enabled]"
#                          (EDR / on-access scan need the Endpoint Security extension; network
#                           protection needs the Network extension). "waiting for user" = not approved.
#     4. Full Disk Access - best effort read of the system TCC.db (info only, never fails the check)
#
#     Remediation: Install_BitdefenderAgent_mac.sh (not installed). Extensions not enabled = deploy the
#     MDM profile (System Extension allow GUNFMW623Y + PPPC FDA) - see that script's header.
#
#     Vendor reference:
#       https://www.bitdefender.com/business/support/en/77211-41491-using-the-command-line-tool.html
#       https://bitdefender.com/business/support/en/77211-199818--runsetupdownloader.html
#
#     N-Sight Monitoring:
#     - Process Check: BDLDaemon
#     - OSX Daemon Check: com.bitdefender.*  (launchctl list | grep -i bitdefender)
#     - LaunchDaemon Path: /Library/LaunchDaemons/com.bitdefender.*.plist
#
# EXIT CODES:
#     0    = OK       (installed, daemon running, all Bitdefender extensions enabled)
#     1001 = WARNING  (some Bitdefender extensions not enabled / waiting for approval)
#     1002 = CRITICAL (not installed, daemon not running, or no Bitdefender extension enabled)
#
# EXECUTION:
#     macOS (local):  sudo bash /path/to/Check_Bitdefender_EDR_mac.sh
#     macOS (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/checks/Check_Bitdefender_EDR_mac.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges
#     Platform: macOS 11+ (Intel & Apple Silicon)
#     Timeout: default 60s
#
# CHANGELOG:
#     1.0 - Initial version
# =============================================================================

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

readonly BD_TEAM_ID="GUNFMW623Y"
readonly BD_DAEMON="/Library/Bitdefender/AVP/BDLDaemon"
readonly BD_APP="/Applications/Endpoint Security for Mac.app"
readonly TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

details=()

if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Root privileges required"
    exit $EXIT_CRITICAL
fi

agent_version() {
    local v=""
    [[ -d "$BD_APP" ]] && v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BD_APP/Contents/Info.plist" 2>/dev/null)
    echo "${v:-unknown}"
}

report() {
    # $1 exit code, $2 status line (first line = dashboard)
    echo "$2"
    local d
    for d in "${details[@]}"; do echo "  $d"; done
    exit "$1"
}

# --- 1. Installed ------------------------------------------------------------
if [[ ! -e "$BD_DAEMON" && ! -d "$BD_APP" ]]; then
    report $EXIT_CRITICAL "CRITICAL: Bitdefender GravityZone agent is NOT installed on $(hostname -s) - run Install_BitdefenderAgent_mac.sh"
fi
VERSION=$(agent_version)
details+=("Version: $VERSION | macOS $(sw_vers -productVersion) ($(uname -m))")

# --- 2. Daemon running -------------------------------------------------------
daemons=$(launchctl list 2>/dev/null | awk 'tolower($3) ~ /bitdefender/ {print $3"(pid "$1")"}' | tr '\n' ' ')
details+=("LaunchDaemons: ${daemons:-none loaded}")
if ! pgrep -qf "BDLDaemon"; then
    report $EXIT_CRITICAL "CRITICAL: Bitdefender EDR - BDLDaemon is not running (v$VERSION)"
fi

# --- 3. System extensions ----------------------------------------------------
crit=""; warn=""
if command -v systemextensionsctl >/dev/null 2>&1; then
    ext_lines=$(systemextensionsctl list 2>/dev/null | grep "$BD_TEAM_ID")
    if [[ -z "$ext_lines" ]]; then
        crit="no Bitdefender system extensions registered"
    else
        total=0; enabled=0; bad=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            id=$(echo "$line" | grep -oE 'com\.bitdefender[A-Za-z0-9._-]*' | head -1)
            state=$(echo "$line" | grep -oE '\[[^]]*\]' | tail -1)
            details+=("Extension: ${id:-?} $state")
            # skip superseded copies left after an upgrade
            [[ "$state" == *"terminated"* || "$state" == *"uninstall"* ]] && continue
            (( total++ ))
            if [[ "$state" == *"activated enabled"* ]]; then
                (( enabled++ ))
            else
                bad+="${id##*.} ${state} "
            fi
        done <<< "$ext_lines"
        if (( enabled == 0 )); then
            crit="no Bitdefender system extension enabled (${bad:-none active}) - approve via MDM"
        elif (( enabled < total )); then
            warn="$((total - enabled))/$total extensions not enabled: ${bad}"
        fi
    fi
else
    details+=("systemextensionsctl not available - extension check skipped")
fi

# --- 4. Full Disk Access (info only) ----------------------------------------
if command -v sqlite3 >/dev/null 2>&1 && [[ -r "$TCC_DB" ]]; then
    fda=$(sqlite3 "$TCC_DB" "SELECT client||'='||auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client LIKE '%itdefender%';" 2>/dev/null | tr '\n' ' ')
    details+=("Full Disk Access (TCC, 2=allowed): ${fda:-no entries / MDM-managed / not readable}")
fi

# --- Result ------------------------------------------------------------------
if [[ -n "$crit" ]]; then
    report $EXIT_CRITICAL "CRITICAL: Bitdefender EDR - $crit (v$VERSION)"
elif [[ -n "$warn" ]]; then
    report $EXIT_WARNING "WARNING: Bitdefender EDR - $warn(v$VERSION)"
else
    report $EXIT_SUCCESS "OK: Bitdefender EDR healthy - v$VERSION, daemon running, extensions enabled"
fi
