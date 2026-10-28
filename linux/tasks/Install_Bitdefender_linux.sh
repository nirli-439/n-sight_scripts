#!/bin/bash
# =============================================================================
# Install_Bitdefender_linux.sh - Unattended GravityZone (BEST) install, Ubuntu + Fedora
# =============================================================================
#
# SYNOPSIS:
#     Downloads the organization's GravityZone setup_downloader.tar, extracts
#     installer + installer.xml + bdconfigure, and runs ./installer as root.
#     The Linux installer is already unattended (DEBIAN_FRONTEND=noninteractive);
#     there is no --silent flag. One script for apt and dnf.
#
# DESCRIPTION:
#     - Skips if bitdefender-security-tools is already registered (idempotent)
#     - Vendor installer detects distro, pulls the deb/rpm, configures epag,
#       starts bdsec. Log: /opt/bitdefender-security-tools/var/log/installer.log
#     - Verifies bdsec.service is active before reporting success
#
#     Vendor reference:
#       https://www.bitdefender.com/business/support/en/77211-157515-bitdefender-endpoint-security-tools-for-linux-quick-start-guide.html
#
# EXIT CODES:
#     0    = Success (installed now, or already installed)
#     1001 = Warning (installer exit 0 but bdsec not active yet)
#     1002 = Critical (download / extract / installer failure)
#
# EXECUTION:
#     Linux (local):  sudo bash /path/to/Install_Bitdefender_linux.sh
#     Linux (repo):   curl -fsSL "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/linux/tasks/Install_Bitdefender_linux.sh" | sudo bash
#
# NOTES:
#     Author: IT Admin
#     Version: 1.0
#     Requires: Root privileges
#     Platform: Ubuntu 20.04+ / Fedora 38+ (systemd). Not rpm-ostree (Kinoite).
#     Timeout: set the N-Sight task timeout to 1200s (installer pulls the full kit)
#
# CHANGELOG:
#     1.0 - Initial version
# =============================================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

readonly SCRIPT_NAME="Install_Bitdefender_linux"
readonly SCRIPT_VERSION="1.0"
readonly LOG_DIR="/var/log/nsight"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1001
readonly EXIT_CRITICAL=1002

# Same GravityZone package as Install_BitdefenderAgent_mac.sh (token jWevAZ)
readonly TAR_URL="https://cloudgz.gravityzone.bitdefender.com/Packages/NIX/0/jWevAZ/setup_downloader.tar"
readonly BD_DIR="/opt/bitdefender-security-tools"
readonly INSTALLER_LOG="${BD_DIR}/var/log/installer.log"
readonly INSTALLER_TIMEOUT=1080
readonly VERIFY_TIMEOUT=120

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${2:-INFO}] $1" >> "$LOG_FILE" 2>/dev/null
}

finish() {
    echo "$2"
    log "$2" "RESULT"
    echo "Log: $LOG_FILE"
    tail -n 15 "$LOG_FILE" 2>/dev/null
    exit "$1"
}

already_installed() {
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' bitdefender-security-tools 2>/dev/null | grep -q 'install ok installed'
        return
    fi
    command -v rpm >/dev/null 2>&1 && rpm -q bitdefender-security-tools >/dev/null 2>&1
}

pkg_version() {
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Version}' bitdefender-security-tools 2>/dev/null
    else
        rpm -q --qf '%{VERSION}-%{RELEASE}' bitdefender-security-tools 2>/dev/null
    fi
}

mkdir -p "$LOG_DIR" 2>/dev/null

if [[ $EUID -ne 0 ]]; then
    echo "CRITICAL: Root privileges required"
    exit $EXIT_CRITICAL
fi

. /etc/os-release 2>/dev/null || true
log "$SCRIPT_NAME v$SCRIPT_VERSION on $(hostname -s) - ${PRETTY_NAME:-unknown} ($(uname -m))"

if already_installed; then
    if ! systemctl is-active --quiet bdsec.service; then
        systemctl start bdsec.service >> "$LOG_FILE" 2>&1 || true
        systemctl is-active --quiet bdsec.service || \
            finish $EXIT_WARNING "WARNING: Bitdefender is registered but bdsec.service is not active - see $INSTALLER_LOG"
    fi
    finish $EXIT_SUCCESS "OK: Bitdefender GravityZone already installed (v$(pkg_version)); bdsec.service is active"
fi

if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "fedora" && "${ID_LIKE:-}" != *debian* && "${ID_LIKE:-}" != *fedora* && "${ID_LIKE:-}" != *rhel* ]]; then
    finish $EXIT_CRITICAL "CRITICAL: Unsupported distro ${ID:-unknown} (need Ubuntu or Fedora)"
fi
if [[ -f /run/ostree-booted || -d /ostree ]]; then
    finish $EXIT_CRITICAL "CRITICAL: rpm-ostree (Kinoite) is not supported by this installer"
fi

command -v curl >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q curl
    fi
} || finish $EXIT_CRITICAL "CRITICAL: curl missing and could not be installed"
command -v tar >/dev/null 2>&1 || finish $EXIT_CRITICAL "CRITICAL: tar missing"

WORK=$(mktemp -d /tmp/bdgz.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log "Downloading $TAR_URL"
if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 600 -o "$WORK/setup_downloader.tar" "$TAR_URL"; then
    finish $EXIT_CRITICAL "CRITICAL: Failed to download setup_downloader.tar (check URL / network)"
fi
SIZE=$(stat -c%s "$WORK/setup_downloader.tar" 2>/dev/null || echo 0)
log "Downloaded ${SIZE} bytes"
if (( SIZE < 1048576 )) || head -c 1024 "$WORK/setup_downloader.tar" | grep -qiE '<html|<!doctype|accessdenied'; then
    finish $EXIT_CRITICAL "CRITICAL: Download is not a tar (${SIZE} bytes) - check the GravityZone package URL"
fi

tar -xf "$WORK/setup_downloader.tar" -C "$WORK" || finish $EXIT_CRITICAL "CRITICAL: Failed to extract setup_downloader.tar"
[[ -f "$WORK/installer" && -f "$WORK/installer.xml" && -f "$WORK/bdconfigure" ]] || \
    finish $EXIT_CRITICAL "CRITICAL: installer, installer.xml, or bdconfigure missing from the tar"
chmod +x "$WORK/installer" "$WORK/bdconfigure"

log "Running installer (unattended). Vendor log: $INSTALLER_LOG"
"$WORK/installer" >> "$LOG_FILE" 2>&1 &
pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= INSTALLER_TIMEOUT )); then
        kill -9 "$pid" 2>/dev/null
        finish $EXIT_CRITICAL "CRITICAL: installer timed out after ${INSTALLER_TIMEOUT}s - see $INSTALLER_LOG"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
wait "$pid"
rc=$?
log "installer exited $rc after ${elapsed}s"
if (( rc != 0 )); then
    tail=$(tail -n 8 "$INSTALLER_LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    finish $EXIT_CRITICAL "CRITICAL: Bitdefender installer failed (exit $rc) ${tail}"
fi

waited=0
until systemctl is-active --quiet bdsec.service || (( waited >= VERIFY_TIMEOUT )); do
    sleep 5
    waited=$((waited + 5))
done

if systemctl is-active --quiet bdsec.service; then
    finish $EXIT_SUCCESS "OK: Bitdefender GravityZone installed (v$(pkg_version)) in $((elapsed + waited))s"
fi
finish $EXIT_WARNING "WARNING: installer exit 0 after ${elapsed}s but bdsec.service is not active - see $INSTALLER_LOG"
