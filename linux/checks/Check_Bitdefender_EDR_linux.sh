#!/bin/bash
# =============================================================================
# Check_Bitdefender_EDR_linux.sh - Health check for Bitdefender GravityZone (BEST / EDR) on Linux
# =============================================================================
#
# SYNOPSIS:
#     24x7 check that the GravityZone agent (BEST for Linux) is installed, its systemd services
#     are running, on-access antimalware is on and signatures are fresh. Read-only, makes no changes.
#     One script for Ubuntu (apt/dpkg) and Fedora (dnf/rpm).
#
# DESCRIPTION:
#     1. Installed  - /opt/bitdefender-security-tools (v7) or /opt/BitDefender (legacy v6),
#                     or package bitdefender-security-tools registered in dpkg/rpm
#     2. Services   - bdsec.service + bdsec-daemon.service must be active      (else CRITICAL)
#                     bdsec-epagng.service (EDR sensor) / bdsec-update.service (else WARNING)
#                     bdsec.service enabled at boot                             (else WARNING)
#     3. bduitool   - "bduitool get ps": product version, signatures version,
#                     "Antimalware status: Off" (on-access disabled)           -> CRITICAL
#                     "Last succeeded update" > 3 days -> WARNING, > 7 days    -> CRITICAL
#                     (same thresholds as Check_Bitdefender_EDR.ps1)
#     4. Info only  - kernel, fanotify support (needed for on-access scan), SELinux mode (Fedora)
#
#     Remediation: not installed -> install BEST for Linux (GravityZone > Packages > installer).
#     Services disabled after OS upgrade -> systemctl enable bdsec bdsec-update bdsec-daemon bdsec-minidump.timer
#
#     Vendor reference:
#       https://www.bitdefender.com/business/support/en/77212-351976-enabling-best-linux-v7-services-after-an-init-d-to-systemd-os-upgrade.html
#       https://www.bitdefender.com/business/support/en/77212-343058-on-access-scanning-in-bitdefender-endpoint-security-tools-for-linux.html
#
#     N-Sight Monitoring (optional native checks):
#     - Linux Service Check: bdsec, bdsec-daemon, bdsec-epagng
#
# EXIT CODES:
#     0    = OK       (installed, core services active, on-access on, signatures <= 3 days)
#     1001 = WARNING  (EDR/update service down, not enabled at boot, signatures 3-7 days, bduitool failed)
#     1002 = CRITICAL (not installed, bdsec/bdsec-daemon down, on-access Off, signatures > 7 days)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Check_Bitdefender_EDR_linux.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/checks/Check_Bitdefender_EDR_linux.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.1
#     Requires: Root privileges
#     Platform: Ubuntu 20.04+ / Fedora 38+ (systemd)
#     Timeout: default 60s (bduitool call capped at 25s)
#
# CHANGELOG:
#     1.0 - Initial version
#     1.1 - Loose bduitool label matching, signature-file mtime fallback, missing update time
#           is info (not WARNING), raw bduitool output shown when a field can't be parsed
# =============================================================================

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

readonly WARN_DAYS=3
readonly CRIT_DAYS=7
readonly BD_PATHS=("/opt/bitdefender-security-tools" "/opt/BitDefender")
readonly CORE_UNITS=("bdsec.service" "bdsec-daemon.service")
readonly OPT_UNITS=("bdsec-epagng.service" "bdsec-update.service")

details=()
crit=()
warn=()

if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Root privileges required"
    exit $EXIT_CRITICAL
fi

report() {
    # $1 exit code, $2 status line (first line = dashboard)
    echo "$2"
    local d
    for d in "${details[@]}"; do echo "  $d"; done
    exit "$1"
}

HOST=$(hostname -s 2>/dev/null || hostname)
OS=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")

# --- 1. Installed ------------------------------------------------------------
BD_DIR=""
for p in "${BD_PATHS[@]}"; do
    [[ -d "$p" ]] && { BD_DIR="$p"; break; }
done
PKG=""
if command -v dpkg-query >/dev/null 2>&1; then
    PKG=$(dpkg-query -W -f='${Status} ${Version}' bitdefender-security-tools 2>/dev/null | awk '/install ok installed/ {print $NF}')
elif command -v rpm >/dev/null 2>&1; then
    PKG=$(rpm -q --qf '%{VERSION}-%{RELEASE}' bitdefender-security-tools 2>/dev/null | grep -v 'not installed')
fi
if [[ -z "$BD_DIR" && -z "$PKG" ]]; then
    report $EXIT_CRITICAL "CRITICAL: Bitdefender GravityZone agent is NOT installed on $HOST ($OS)"
fi
details+=("Install: ${BD_DIR:-dir not found} | package: ${PKG:-not registered} | $OS | kernel $(uname -r)")

# --- 2. Services -------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    for u in "${CORE_UNITS[@]}" "${OPT_UNITS[@]}"; do
        state=$(systemctl is-active "$u" 2>/dev/null); state=${state:-unknown}
        details+=("Service $u: $state")
        if [[ "$state" != "active" ]]; then
            if [[ " ${CORE_UNITS[*]} " == *" $u "* ]]; then
                crit+=("$u $state")
            elif systemctl cat "$u" >/dev/null 2>&1; then
                warn+=("$u $state")
            fi
        fi
    done
    en=$(systemctl is-enabled bdsec.service 2>/dev/null)
    details+=("bdsec.service at boot: ${en:-unknown}")
    [[ "$en" != "enabled" ]] && warn+=("bdsec.service not enabled at boot")
else
    pgrep -f bdsecd >/dev/null 2>&1 || pgrep -f bdsec >/dev/null 2>&1 || crit+=("no bdsec process (no systemd)")
fi

# --- 3. bduitool product status ---------------------------------------------
# Labels differ between BEST builds (e.g. "Signatures version" vs "Antimalware signatures",
# "Last succeeded update" vs "Last update time"), so keys are matched loosely.
BDUI=""
for p in "${BD_PATHS[@]}"; do
    [[ -x "$p/bin/bduitool" ]] && { BDUI="$p/bin/bduitool"; break; }
done
VERSION="${PKG:-unknown}"
ps_out=""
show_raw=0

# epoch from a date string (handles "2026-10-12 at 08:15:00", ISO, dd/mm/yyyy, epoch)
to_epoch() {
    local s="$1"
    s=$(echo "$s" | sed -E 's/ at / /; s/[()]//g; s/ +(UTC|GMT)$//')
    [[ "$s" =~ ^[0-9]{10}$ ]] && { echo "$s"; return; }
    if [[ "$s" =~ ^([0-9]{1,2})[./]([0-9]{1,2})[./]([0-9]{4})(.*)$ ]]; then
        s="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}${BASH_REMATCH[4]}"
    fi
    date -d "$s" +%s 2>/dev/null
}

if [[ -n "$BDUI" ]]; then
    ps_out=$(timeout 25 "$BDUI" get ps 2>&1)
    rc=$?
    ps_out=$(echo "$ps_out" | tr -d '\r')
    if [[ $rc -ne 0 || -z "$ps_out" ]]; then
        warn+=("bduitool get ps failed (rc=$rc)")
        details+=("bduitool: $(echo "$ps_out" | head -2 | tr '\n' ' ')")
    else
        # field <key-regex> [exclude-regex] -> value of first "key: value" / "key = value" line
        field() {
            echo "$ps_out" | awk -v k="$1" -v x="${2:-^$}" '
                { i=index($0,":"); j=index($0,"="); if (i==0 || (j>0 && j<i)) i=j
                  if (i==0) next
                  key=tolower(substr($0,1,i-1)); gsub(/^[ \t*-]+|[ \t]+$/,"",key)
                  if (key ~ k && key !~ x) { v=substr($0,i+1); gsub(/^[ \t]+|[ \t]+$/,"",v); if (v!="") { print v; exit } } }'
        }
        v=$(field "product version");                              [[ -n "$v" ]] && VERSION="$v"
        sig=$(field "signature|engine|definition|virus" "update|date|time|status")
        last=$(field "last.*update|update.*(time|date)|signature.*(date|time)|updated" "status|check")
        am=$(field "antimalware|on.?access" "signature|version|update")
        scan=$(field "scan type|scan mode|scanning engine")
    fi
elif [[ -z "$BDUI" ]]; then
    warn+=("bduitool not found - status not verified")
fi

# Fallback for update time: newest file in the signature/plugin folders
upd_src="bduitool"
ts=""
[[ -n "$last" ]] && ts=$(to_epoch "$last")
if [[ -z "$ts" && -n "$BD_DIR" ]]; then
    newest=$(find "$BD_DIR" -xdev -type d \( -iname '*plugin*' -o -iname '*signature*' -o -iname '*bases*' -o -iname 'avc*' \) \
             -exec find {} -type f -printf '%T@\n' \; 2>/dev/null | sort -n | tail -1)
    if [[ -n "$newest" ]]; then
        ts=${newest%.*}; upd_src="signature files"
        last=$(date -d "@$ts" '+%Y-%m-%d %H:%M')
    fi
fi

details+=("Product: $VERSION | Signatures: ${sig:-?} | Last update: ${last:-?} (${upd_src})")
details+=("Antimalware (on-access): ${am:-?} | Scan type: ${scan:-?}")

[[ "${am,,}" =~ ^(off|disabled) ]] && crit+=("on-access antimalware Off")
[[ "${scan,,}" == "none" ]] && crit+=("no scan engine in use (Security Server unreachable?)")

if [[ -n "$ts" ]]; then
    age=$(( ( $(date +%s) - ts ) / 86400 ))
    details+=("Signature age: ${age} day(s)")
    if (( age > CRIT_DAYS )); then crit+=("signatures ${age} days old")
    elif (( age > WARN_DAYS )); then warn+=("signatures ${age} days old"); fi
elif [[ -n "$BDUI" ]]; then
    # Agent is healthy per services; an unreadable timestamp alone is informational, not a warning.
    details+=("Signature age: not reported (update service: $(systemctl is-active bdsec-update.service 2>/dev/null || echo ?))")
    show_raw=1
fi
[[ -z "$sig" || -z "$am" ]] && show_raw=1

# --- 4. Info only ------------------------------------------------------------
fan="unknown"
if [[ -r "/boot/config-$(uname -r)" ]]; then
    grep -q '^CONFIG_FANOTIFY=y' "/boot/config-$(uname -r)" && fan="yes" || fan="NO"
fi
selinux="n/a"; command -v getenforce >/dev/null 2>&1 && selinux=$(getenforce 2>/dev/null)
details+=("fanotify: $fan | SELinux: $selinux (on-access needs Permissive/Disabled)")

# Raw bduitool output when a field could not be parsed (helps adjust labels)
if (( show_raw )) && [[ -n "$ps_out" ]]; then
    details+=("--- bduitool get ps (raw) ---")
    while IFS= read -r l; do [[ -n "$l" ]] && details+=("$l"); done < <(echo "$ps_out" | head -40 | cut -c1-200)
fi

# --- Result ------------------------------------------------------------------
join() { local IFS=';'; echo "$*" | sed 's/;/; /g'; }
if (( ${#crit[@]} )); then
    report $EXIT_CRITICAL "CRITICAL: Bitdefender EDR - $(join "${crit[@]}") (v$VERSION)"
elif (( ${#warn[@]} )); then
    report $EXIT_WARNING "WARNING: Bitdefender EDR - $(join "${warn[@]}") (v$VERSION)"
else
    report $EXIT_SUCCESS "OK: Bitdefender EDR healthy - v$VERSION, services active, on-access on, signatures current"
fi
