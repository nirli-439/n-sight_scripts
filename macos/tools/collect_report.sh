#!/bin/bash
# collect_report.sh - one zip with everything needed to analyze a Helfy Mac after onboarding
# (MDM profiles, privacy approvals, system extensions, vendor signatures, onboarding logs,
# the PPPC builder result). Nothing leaves the Mac: the zip lands on the Desktop and the
# technician AirDrops it to Nir, who gives it to Claude to analyze.
#
#   curl -fsSL is.gd/helfyreport | bash
#   (= https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/tools/collect_report.sh)
#
# Read-only except for the files it writes. Asks for the admin password once (some checks
# need root); without it the report is still made, just with fewer details. Bash 3.2.

collect_report() {
set -o pipefail
local RAW=https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main
local host stamp dir zip root=0
host=$(scutil --get ComputerName 2>/dev/null | tr -cd 'A-Za-z0-9._-'); [[ -n "$host" ]] || host=mac
stamp=$(date +%Y%m%d-%H%M%S)
dir=$(mktemp -d "${TMPDIR:-/tmp}/helfy-report.XXXXXX")/Helfy-report-$host-$stamp
zip="${HELFY_REPORT_OUT:-$HOME/Desktop}/Helfy-report-$host-$stamp.zip"
mkdir -p "$dir" || { echo 'Cannot create a temp folder.'; return 1; }

echo 'Helfy Mac report - collecting (about 1 minute)...'
echo 'Admin password (some checks need it; Enter 3x to skip):'
if { /usr/bin/sudo -v </dev/tty; } 2>/dev/null; then root=1; else echo '  continuing without admin checks'; fi
S() { if [[ $root == 1 ]]; then /usr/bin/sudo -n "$@"; else "$@"; fi; }

# run FILE TITLE CMD... : append command + output (stdout+stderr) to a section file.
run() {
    local f="$dir/$1" title="$2"; shift 2
    { echo "===== $title"; echo "\$ $*"; "$@" 2>&1; echo "(exit $?)"; echo; } >>"$f"
}
# Commands that can hang (log show): kill after N seconds.
run_max() {
    local secs=$1; shift
    ( run "$@" ) & local p=$!
    ( sleep "$secs"; kill "$p" ) >/dev/null 2>&1 & local w=$!
    wait "$p" 2>/dev/null; kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
}

echo '  system'
run 01-system.txt 'date' date
run 01-system.txt 'macOS' sw_vers
run 01-system.txt 'hardware (model, serial, activation lock)' system_profiler SPHardwareDataType
run 01-system.txt 'names' sh -c 'scutil --get ComputerName; scutil --get LocalHostName; scutil --get HostName 2>&1'
run 01-system.txt 'console user' stat -f %Su /dev/console
run 01-system.txt 'local users' dscl . -list /Users UniqueID
run 01-system.txt 'admin group' dscl . -read /Groups/admin GroupMembership
run 01-system.txt 'FileVault' fdesetup status
run 01-system.txt 'SIP' csrutil status
run 01-system.txt 'Gatekeeper' spctl --status
run 01-system.txt 'firewall' /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate --getstealthmode
run 01-system.txt 'power' pmset -g custom
run 01-system.txt 'time' sh -c 'systemsetup -getusingnetworktime 2>&1; systemsetup -gettimezone 2>&1'
run 01-system.txt 'disk' df -h /

echo '  MDM + profiles'
run 02-mdm.txt 'enrollment' profiles status -type enrollment
run 02-mdm.txt 'enrollment details (ABM / DEP)' S profiles show -type enrollment
run 02-mdm.txt 'installed profiles' S profiles list -all
run 02-mdm.txt 'installed profiles (full)' S profiles show -all
run 02-mdm.txt 'MDM privacy overrides (PPPC actually applied)' S plutil -p '/Library/Application Support/com.apple.TCC/MDMOverrides.plist'

echo '  privacy approvals (TCC)'
local q="select service, client, client_type, auth_value, auth_reason, datetime(last_modified,'unixepoch') from access order by service, client;"
run 03-privacy.txt 'system TCC (auth_value 2 = allowed, 0 = denied)' S sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' "$q"
run 03-privacy.txt 'user TCC' sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "$q"
echo '    (if these say "authorization denied": Terminal has no Full Disk Access - fine, MDMOverrides above still shows the profile)' >>"$dir/03-privacy.txt"

echo '  system + network extensions'
run 04-extensions.txt 'system extensions' systemextensionsctl list
run 04-extensions.txt 'VPN / network services' scutil --nc list
run 04-extensions.txt 'content filters + VPN config' S plutil -p /Library/Preferences/com.apple.networkextension.plist
run 04-extensions.txt 'kernel extensions (3rd party)' sh -c 'kmutil showloaded --list-only 2>/dev/null | grep -v com.apple'

echo '  security apps (signatures, services)'
local f=05-vendors.txt p
run $f 'vendor daemons' sh -c "launchctl print system 2>/dev/null | grep -iE 'bitdefender|bdl|epsecurity|rmm|n-able|nable|msp|anywhere|takecontrol|twingate'"
run $f 'vendor processes' sh -c "ps axo user,pid,etime,command | grep -iE 'bitdefender|bdl|epsecurity|rmm|n-able|msp|anywhere|takecontrol|twingate' | grep -v grep"
run $f 'vendor launchd plists' sh -c "ls -l /Library/LaunchDaemons /Library/LaunchAgents | grep -iE 'bitdefender|bd|epsecurity|rmm|n-able|msp|anywhere|takecontrol|twingate'"
run $f 'installed apps' ls /Applications /Applications/Utilities
run $f 'vendor folders' sh -c 'ls -la /Library/Bitdefender /Library/Bitdefender/AVP /usr/local/rmmagent /Library/MSP* "/Library/Application Support/MSP"* "/Library/Application Support/BitDefender" 2>&1'
while IFS= read -r p; do
    [[ -e "$p" ]] || continue
    run $f "signature: $p" sh -c 'codesign -dv --verbose=2 "$1" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority|Timestamp|Format)="; codesign -d -r- "$1" 2>&1 | grep designated; spctl -a -vv "$1" 2>&1 | head -3' _ "$p"
done < <( { ls -d /Applications/*.app 2>/dev/null | grep -iE 'bitdefender|endpoint|msp|anywhere|take ?control|twingate|n-able|nsight'
            ls -d /Library/SystemExtensions/*/*.systemextension 2>/dev/null
            find /Library/Bitdefender /usr/local/rmmagent /Library/MSP\ Anywhere* /Library/Application\ Support/MSP\ Anywhere* \
                 -maxdepth 5 \( -name '*.app' -type d \) 2>/dev/null
            find /usr/local/rmmagent /Library/Bitdefender/AVP -maxdepth 1 -type f -perm -u+x 2>/dev/null; } | sort -u )

echo '  PPPC builder (dry run into the report)'
local builder
builder=$(mktemp "${TMPDIR:-/tmp}/helfy-pppc.XXXXXX") \
  && curl -fsSL --max-time 60 "$RAW/macos/profiles/build_helfy_pppc.sh" -o "$builder" 2>>"$dir/06-pppc-builder.txt" \
  && run 06-pppc-builder.txt 'build_helfy_pppc.sh' /bin/bash "$builder" "$dir/Helfy_Security_Apps_Privacy.mobileconfig"
rm -f "$builder"

echo '  recent privacy / extension prompts (last 2 h)'
run_max 90 07-recent-prompts.txt 'TCC + sysextd + nesessionmanager (vendors only)' sh -c \
  "log show --last 2h --style compact --predicate 'subsystem == \"com.apple.TCC\" OR process == \"sysextd\" OR process == \"nesessionmanager\"' 2>/dev/null | grep -iE 'bitdefender|bdl|epsecurity|rmm|n-able|msp|anywhere|takecontrol|twingate|GUNFMW623Y|6GX8KVTR9H' | tail -400"

echo '  onboarding logs'
mkdir -p "$dir/onboarding-logs"
cp -p "$HOME"/Library/Logs/Helfy/* "$dir/onboarding-logs/" 2>/dev/null || echo 'no onboarding logs in ~/Library/Logs/Helfy' >"$dir/onboarding-logs/none.txt"

# Short summary on top.
{
echo "Helfy Mac report  $(date '+%Y-%m-%d %H:%M')  $host"
echo "macOS $(sw_vers -productVersion)  $(sysctl -n hw.model)  admin checks: $([[ $root == 1 ]] && echo yes || echo no)"
echo "MDM: $(profiles status -type enrollment 2>/dev/null | tr '\n' ' ')"
echo "Helfy profiles: $(S profiles list -all 2>/dev/null | grep -o 'co\.helfy\.profile\.[a-z-]*' | sort -u | tr '\n' ' ')"
echo "FileVault: $(fdesetup status 2>/dev/null | head -1)"
echo "System extensions: $(systemextensionsctl list 2>/dev/null | grep -c 'activated enabled') activated+enabled, $(systemextensionsctl list 2>/dev/null | grep -ciE 'waiting|awaiting') waiting for user"
echo "PPPC builder: $(grep -E '^Wrote|Nothing found|invalid' "$dir/06-pppc-builder.txt" 2>/dev/null | tail -1 | sed 's|^Wrote .*/|Wrote |')"
} >"$dir/00-summary.txt"

# Zip to the Desktop and show it.
( cd "$(dirname "$dir")" && /usr/bin/ditto -c -k --keepParent "$(basename "$dir")" "$zip" ) || { echo "Zip failed - the files are in $dir"; return 1; }
rm -rf "$(dirname "$dir")"
echo
cat <<EOF
Done: $zip
Next: AirDrop this zip to Nir (Finder window is open). Nir: tell Claude "analyze the Mac report".
EOF
[[ -z "$HELFY_REPORT_OUT" ]] && /usr/bin/open -R "$zip" 2>/dev/null
return 0
}
collect_report "$@"
