#!/bin/bash
# Ubuntu 22.04+ Twingate client from the official signed APT repository.
# https://www.twingate.com/docs/linux
# N-Sight Automated Task, timeout 900. EXIT: 0 OK | 1001 unsupported/conflict | 1002 error.
# Install only: no network setup, credentials, login, or connection changes.
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
trap 'echo "CRITICAL: Twingate installation failed (line $LINENO)"; exit 1002' ERR

[ "$(id -u)" -eq 0 ] || { echo 'CRITICAL: Root required'; exit 1002; }
[ "$(uname -s)" = Linux ] && [ -r /etc/os-release ] || { echo 'WARNING: Ubuntu 22.04+ required'; exit 1001; }
. /etc/os-release
if [ "${ID:-}" != ubuntu ] || ! [[ "${VERSION_ID:-}" =~ ^([0-9]+)\.([0-9]+)$ ]] || (( 10#${BASH_REMATCH[1]} < 22 || (10#${BASH_REMATCH[1]} == 22 && 10#${BASH_REMATCH[2]} < 4) )); then
    echo 'WARNING: Ubuntu 22.04+ required'; exit 1001
fi
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) echo "WARNING: Unsupported Twingate architecture: $arch"; exit 1001 ;; esac
command -v systemctl >/dev/null || { echo 'CRITICAL: systemd required'; exit 1002; }
installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = 'install ok installed' ]; }
if installed twingate-latest; then
    echo 'WARNING: Conflicting twingate-latest release channel installed; resolve manually. Nothing removed.'
    exit 1001
fi
if installed twingate; then
    version=$(twingate --version)
    [ -n "$version" ] || { echo 'CRITICAL: Empty Twingate version'; exit 1002; }
    echo "OK: $version already installed; network configuration unchanged."
    exit 0
fi
apt-get update -qq
apt-get install -y -qq --no-remove ca-certificates curl gnupg
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL https://packages.twingate.com/apt/gpg.key -o "$work/twingate.asc"
gpg --batch --dearmor --output "$work/twingate.gpg" "$work/twingate.asc"
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
install -m 0644 "$work/twingate.gpg" /usr/share/keyrings/twingate-client-keyring.gpg
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/twingate-client-keyring.gpg] https://packages.twingate.com/apt/ * *' > "$work/twingate.list"
install -m 0644 "$work/twingate.list" /etc/apt/sources.list.d/twingate.list
apt-get update -qq
apt-get install -y -qq --no-remove twingate
installed twingate || { echo 'CRITICAL: Twingate package missing after install'; exit 1002; }
version=$(twingate --version)
[ -n "$version" ] || { echo 'CRITICAL: Empty Twingate version'; exit 1002; }
echo "OK: $version installed and verified. Network setup/login remains a manual step."
exit 0
