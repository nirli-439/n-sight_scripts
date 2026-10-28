#!/bin/bash
# Ubuntu 22.04+ Docker Engine and current Compose plugin, official signed APT repo.
# https://docs.docker.com/engine/install/ubuntu/
# N-Sight Automated Task, timeout 1200. EXIT: 0 OK | 1001 unsupported/conflict | 1002 error.
# Preserves containers/images/config. Never removes packages or grants docker-group access.
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
trap 'echo "CRITICAL: Docker installation failed (line $LINENO)"; exit 1002' ERR

[ "$(id -u)" -eq 0 ] || { echo 'CRITICAL: Root required'; exit 1002; }
[ "$(uname -s)" = Linux ] && [ -r /etc/os-release ] || { echo 'WARNING: Ubuntu 22.04+ required'; exit 1001; }
. /etc/os-release
if [ "${ID:-}" != ubuntu ] || ! [[ "${VERSION_ID:-}" =~ ^([0-9]+)\.([0-9]+)$ ]] || (( 10#${BASH_REMATCH[1]} < 22 || (10#${BASH_REMATCH[1]} == 22 && 10#${BASH_REMATCH[2]} < 4) )); then
    echo 'WARNING: Ubuntu 22.04+ required'; exit 1001
fi
codename=${VERSION_CODENAME:-}
[[ "$codename" =~ ^[a-z]+$ ]] || { echo 'CRITICAL: Invalid Ubuntu codename'; exit 1002; }
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64|armhf|s390x|ppc64el) ;; *) echo "WARNING: Unsupported Docker architecture: $arch"; exit 1001 ;; esac
command -v systemctl >/dev/null || { echo 'CRITICAL: systemd required'; exit 1002; }
installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = 'install ok installed' ]; }
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if installed "$pkg"; then
        echo "WARNING: Conflicting package $pkg installed; resolve manually. Nothing removed."
        exit 1001
    fi
done
verify() {
    local compose_version
    docker --version >/dev/null 2>&1 &&
    compose_version=$(docker compose version --short 2>/dev/null) &&
    [[ "$compose_version" =~ ^v?([2-9]|[1-9][0-9]+)\. ]] &&
    systemctl is-active --quiet docker.service &&
    docker --host unix:///var/run/docker.sock info --format '{{.ServerVersion}}' >/dev/null 2>&1
}
complete=true
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    installed "$pkg" || complete=false
done
if "$complete" && verify; then
    echo 'OK: Docker Engine, Compose plugin and local daemon already verified; no changes.'
    exit 0
fi
# Never silently downgrade or replace a differently managed Compose installation.
if installed docker-compose-plugin; then
    compose_version=$(docker compose version --short 2>/dev/null || true)
    if [ -n "$compose_version" ] && ! [[ "$compose_version" =~ ^v?([2-9]|[1-9][0-9]+)\. ]]; then
        echo "WARNING: Existing Compose $compose_version is not a supported Compose plugin; resolve manually."
        exit 1001
    fi
fi
# A healthy installed stack with only a stopped daemon needs no APT/network changes.
if ! "$complete"; then
    apt-get update -qq
    apt-get install -y -qq --no-remove ca-certificates curl gnupg
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$work/docker.asc"
    gpg --batch --dearmor --output "$work/docker.gpg" "$work/docker.asc"
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    install -m 0644 "$work/docker.gpg" /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" > "$work/docker.list"
    install -m 0644 "$work/docker.list" /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq --no-remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker.service
verify || { echo 'CRITICAL: Docker CLI, Compose plugin or local daemon verification failed'; exit 1002; }
echo 'OK: Docker Engine, Compose plugin and local daemon verified. No user added to docker group (root-equivalent).'
exit 0
