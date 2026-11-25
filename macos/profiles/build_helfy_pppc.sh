#!/bin/bash
# build_helfy_pppc.sh - build the MDM profile that pre-approves Bitdefender + N-sight / MSP Anywhere /
# Take Control on macOS (no "Allow" clicks in System Settings).
#
# Run ONCE on a Mac where those are already installed and working (e.g. a freshly onboarded one):
#   curl -fsSL https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/macos/profiles/build_helfy_pppc.sh | bash
# Writes ~/Desktop/Helfy_Security_Apps_Privacy.mobileconfig -> upload it in N-sight > Device
# Management for Apple > Profiles (Customer Israel(Helfy)) and deploy to all Macs.
# Re-run + re-upload after a vendor changes its signing (rare; same profile ID = replaces).
#
# What the profile contains (all values read from the real signed binaries - nothing guessed):
#   Privacy (PPPC): Full Disk Access + Accessibility + PostEvent ALLOWED for every component.
#     Screen Recording + Input Monitoring: Apple forbids MDM to grant these. They are set to
#     "standard user may allow" - one click by the user (no admin password) for remote control.
#   Network content filter (com.apple.webcontent-filter): for Bitdefender's filter extensions, so
#     the "Allow ... to filter network content" prompt does not appear.
# No python needed (fresh Macs have none). Bash 3.2.

set -o pipefail
TEAMS="${HELFY_PPPC_TEAMS:-GUNFMW623Y 6GX8KVTR9H}"   # Bitdefender, Twingate; N-able team read from rmmagentd
OUT="${1:-$HOME/Desktop/Helfy_Security_Apps_Privacy.mobileconfig}"
PREFIX=co.helfy.profile.security-apps-privacy

esc() { local s="$1"; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
uuid_of() { local h; h=$(printf '%s' "$1" | shasum -a 256 | tr 'a-f' 'A-F'); printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"; }
team_of() { codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}'; }
dr_of() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' | head -1; }
bid_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }
is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

# N-able (N-sight agent) team from the installed agent itself.
for b in /usr/local/rmmagent/rmmagentd /usr/local/bin/rmmagentd; do
    [[ -x "$b" ]] && { t=$(team_of "$b"); [[ -n "$t" ]] && TEAMS="$TEAMS $t"; break; }
done
wanted_team() { local t; for t in $TEAMS; do [[ "$1" == "$t" ]] && return 0; done; return 1; }

IDS=()      # "type|identifier|requirement"
seen=' '
add_id() {   # add_id TYPE IDENTIFIER PATH
    local req team
    [[ "$seen" == *" $2 "* ]] && return 0
    team=$(team_of "$3"); wanted_team "$team" || return 0
    [[ "$team" != 6GX8KVTR9H ]] || return 0   # Twingate: VPN approval only, no privacy access
    req=$(dr_of "$3"); [[ -n "$req" ]] || { echo "  skip (no requirement): $3" >&2; return 0; }
    IDS+=("$1|$2|$req"); seen="$seen$2 "
    echo "  + $2  ($team)" >&2
}

echo 'Scanning installed Bitdefender / N-sight / MSP Anywhere / Take Control...' >&2
# App bundles.
while IFS= read -r app; do
    b=$(bid_of "$app"); [[ -n "$b" ]] && add_id bundleID "$b" "$app"
done < <( { ls -d /Applications/*.app /Applications/Utilities/*.app 2>/dev/null
            find /Library/Bitdefender /Library/Application\ Support/BitDefender /usr/local/rmmagent \
                 /Library/MSP\ Anywhere* /Library/Application\ Support/MSP\ Anywhere* \
                 -maxdepth 5 -name '*.app' -type d 2>/dev/null
            ${HELFY_PPPC_EXTRA_APPS:+printf '%s\n' "${HELFY_PPPC_EXTRA_APPS//:/$'\n'}"}; } | sort -u )
# Command-line daemons/tools (identified by path).
while IFS= read -r bin; do
    is_macho "$bin" && add_id path "$bin" "$bin"
done < <(find /usr/local/rmmagent /Library/Bitdefender/AVP /Library/Bitdefender/AVP/*/ \
              -maxdepth 1 -type f -perm -u+x 2>/dev/null | sort -u)
# System extensions (endpoint security / network) need Full Disk Access too.
FILTERS=()  # "app_bundle|provider_bundle|requirement|kind"
seenx=' '
VPNS=()     # "app_bundle|provider_bundle|requirement" (Twingate packet tunnel)
for ext in /Library/SystemExtensions/*/*.systemextension; do
    [[ -d "$ext" ]] || continue
    eb=$(bid_of "$ext"); [[ -n "$eb" ]] || continue
    add_id bundleID "$eb" "$ext"
    wanted_team "$(team_of "$ext")" || continue
    classes=$(/usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEProviderClasses' "$ext/Contents/Info.plist" 2>/dev/null)
    container=$(find /Applications /Library/Bitdefender -maxdepth 6 -type d -path "*/Contents/Library/SystemExtensions/$eb.systemextension" 2>/dev/null | head -1)
    capp=${container%%/Contents/Library/SystemExtensions/*}
    cb=$([[ -n "$capp" ]] && bid_of "$capp")
    [[ -n "$cb" ]] || continue
    [[ "$seenx" == *" $eb "* ]] && continue; seenx="$seenx$eb "   # old versions awaiting uninstall
    [[ "$classes" == *filter-data* ]] && FILTERS+=("$cb|$eb|$(dr_of "$ext")|data")
    [[ "$classes" == *filter-packet* ]] && FILTERS+=("$cb|$eb|$(dr_of "$ext")|packet")
    [[ "$classes" == *packet-tunnel* ]] && VPNS+=("$cb|$eb|$(dr_of "$ext")")
done

[[ ${#IDS[@]} -gt 0 || ${#VPNS[@]} -gt 0 || ${#FILTERS[@]} -gt 0 ]] || { echo 'Nothing found - run this on a Mac where Bitdefender and the N-sight agent are installed.' >&2; exit 1; }

entry() {  # entry TYPE ID REQ ALLOWKEY
    local allow
    if [[ "$4" == standard ]]; then allow='<key>Authorization</key><string>AllowStandardUserToSetSystemService</string>'
    else allow='<key>Allowed</key><true/>'; fi
    printf '<dict><key>Identifier</key><string>%s</string><key>IdentifierType</key><string>%s</string><key>CodeRequirement</key><string>%s</string>%s</dict>\n' \
        "$(esc "$2")" "$1" "$(esc "$3")" "$allow"
}
service() {  # service NAME MODE
    local i t id req
    printf '<key>%s</key><array>\n' "$1"
    for i in "${IDS[@]}"; do t=${i%%|*}; id=${i#*|}; id=${id%%|*}; req=${i#*|*|}; entry "$t" "$id" "$req" "$2"; done
    printf '</array>\n'
}

{
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadType</key><string>Configuration</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>$PREFIX</string><key>PayloadUUID</key><string>$(uuid_of $PREFIX)</string>
<key>PayloadDisplayName</key><string>Helfy - Security apps privacy</string>
<key>PayloadDescription</key><string>Pre-approves Bitdefender and N-sight / MSP Anywhere / Take Control (Full Disk Access, Accessibility, network filter).</string>
<key>PayloadOrganization</key><string>Helfy</string><key>PayloadScope</key><string>System</string>
<key>PayloadRemovalDisallowed</key><true/>
<key>PayloadContent</key><array>
EOF
if [[ ${#IDS[@]} -gt 0 ]]; then
cat <<EOF
<dict>
<key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>$PREFIX.tcc</string><key>PayloadUUID</key><string>$(uuid_of $PREFIX.tcc)</string>
<key>PayloadDisplayName</key><string>Privacy (PPPC)</string>
<key>Services</key><dict>
EOF
service SystemPolicyAllFiles allow
service Accessibility allow
service PostEvent allow
service ScreenCapture standard
service ListenEvent standard
echo '</dict></dict>'
fi
n=0
for f in "${FILTERS[@]}"; do
    IFS='|' read -r app prov req kind <<<"$f"
    n=$((n + 1))
    printf '<dict><key>PayloadType</key><string>com.apple.webcontent-filter</string><key>PayloadVersion</key><integer>1</integer>'
    printf '<key>PayloadIdentifier</key><string>%s.filter%s</string><key>PayloadUUID</key><string>%s</string>' "$PREFIX" "$n" "$(uuid_of "$PREFIX.filter.$prov.$kind")"
    printf '<key>PayloadDisplayName</key><string>Network filter %s</string>' "$(esc "$prov")"
    printf '<key>FilterType</key><string>Plugin</string><key>UserDefinedName</key><string>%s</string><key>PluginBundleID</key><string>%s</string><key>FilterGrade</key><string>firewall</string>' "$(esc "$app")" "$(esc "$app")"
    if [[ $kind == data ]]; then
        printf '<key>FilterSockets</key><true/><key>FilterDataProviderBundleIdentifier</key><string>%s</string><key>FilterDataProviderDesignatedRequirement</key><string>%s</string>' "$(esc "$prov")" "$(esc "$req")"
    else
        printf '<key>FilterPackets</key><true/><key>FilterPacketProviderBundleIdentifier</key><string>%s</string><key>FilterPacketProviderDesignatedRequirement</key><string>%s</string>' "$(esc "$prov")" "$(esc "$req")"
    fi
    printf '</dict>\n'
done
n=0
for v in "${VPNS[@]}"; do
    IFS='|' read -r app prov req <<<"$v"
    n=$((n + 1))
    # Pre-approved VPN configuration: no "would like to add VPN configurations" prompt.
    printf '<dict><key>PayloadType</key><string>com.apple.vpn.managed</string><key>PayloadVersion</key><integer>1</integer>'
    printf '<key>PayloadIdentifier</key><string>%s.vpn%s</string><key>PayloadUUID</key><string>%s</string>' "$PREFIX" "$n" "$(uuid_of "$PREFIX.vpn.$prov")"
    printf '<key>PayloadDisplayName</key><string>VPN %s</string><key>UserDefinedName</key><string>%s</string>' "$(esc "$app")" "$(esc "${app##*.}")"
    printf '<key>VPNType</key><string>VPN</string><key>VPNSubType</key><string>%s</string>' "$(esc "$app")"
    printf '<key>VPN</key><dict><key>AuthenticationMethod</key><string>Password</string><key>RemoteAddress</key><string>%s</string>' "$(esc "${app##*.}")"
    printf '<key>ProviderBundleIdentifier</key><string>%s</string><key>ProviderDesignatedRequirement</key><string>%s</string><key>ProviderType</key><string>packet-tunnel</string></dict>' "$(esc "$prov")" "$(esc "$req")"
    printf '</dict>\n'
done
echo '</array></dict></plist>'
} > "$OUT"

plutil -lint "$OUT" >&2 || { echo 'Generated profile is invalid - not uploading it.' >&2; exit 1; }
echo >&2
echo "Wrote $OUT  (${#IDS[@]} components, ${#FILTERS[@]} network filter(s), ${#VPNS[@]} VPN extension(s))" >&2
echo 'Upload it in N-sight > Device Management for Apple > Profiles, name "Helfy - Security apps privacy", deploy to all Macs.' >&2
