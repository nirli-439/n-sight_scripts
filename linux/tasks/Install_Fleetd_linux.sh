#!/bin/bash
# Install_Fleetd_linux.sh - install and enroll Fleet Desktop agent
# For N-Sight RMM deployment
#
# EXIT: 0 success | 1002 critical
# N-Sight: Automated Task | OS=Linux | timeout 600

set -eu
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

URL='http://172.31.100.88:1337'
SECRET='w/0gIE+nvkpFBuQ38lm3Szyzn2oQOpk5'
VERSION='4.90.1'
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in amd64|x86_64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "CRITICAL: unsupported architecture: $ARCH"; exit 1002 ;; esac

if [ "$(id -u)" -ne 0 ]; then echo 'CRITICAL: Root required'; exit 1002; fi
if command -v orbit >/dev/null 2>&1 && orbit --version >/dev/null 2>&1; then echo 'OK: Fleetd already installed'; exit 0; fi

apt-get update -qq >/dev/null 2>&1 || { echo 'CRITICAL: apt update failed'; exit 1002; }
apt-get install -y -qq ca-certificates curl >/dev/null 2>&1 || { echo 'CRITICAL: dependencies failed'; exit 1002; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/fleetdm/fleet/releases/download/fleet-v${VERSION}/fleetctl_v${VERSION}_linux_${ARCH}.tar.gz" -o "$TMP/fleetctl.tgz" || { echo 'CRITICAL: fleetctl download failed'; exit 1002; }
tar -xzf "$TMP/fleetctl.tgz" -C "$TMP" || { echo 'CRITICAL: fleetctl extract failed'; exit 1002; }
FLEETCTL=$(find "$TMP" -type f -name fleetctl -perm -u+x | head -1)
[ -n "$FLEETCTL" ] || { echo 'CRITICAL: fleetctl not found'; exit 1002; }
"$FLEETCTL" package --type=deb --enable-scripts --fleet-desktop --fleet-url="$URL" --enroll-secret="$SECRET" --package-name=fleetd --dir="$TMP" >/dev/null || { echo 'CRITICAL: package build failed'; exit 1002; }
DEB=$(find "$TMP" -maxdepth 1 -name '*.deb' | head -1)
[ -n "$DEB" ] || { echo 'CRITICAL: package missing'; exit 1002; }
dpkg -i "$DEB" >/dev/null 2>&1 || { apt-get install -f -y -qq >/dev/null 2>&1 && dpkg -i "$DEB" >/dev/null 2>&1; } || { echo 'CRITICAL: install failed'; exit 1002; }
systemctl is-active --quiet orbit || { echo 'CRITICAL: orbit is not active'; exit 1002; }
echo "OK: Fleetd enrolled on $(hostname)"
exit 0
