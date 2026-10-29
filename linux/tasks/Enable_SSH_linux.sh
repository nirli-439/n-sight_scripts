#!/bin/bash
# Ubuntu 22.04+: install and enable OpenSSH server; preserve config/keys/firewall.
# EXIT 0 verified | 1001 unsupported/non-systemd | 1002 install/config/service failure.
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
trap 'echo "CRITICAL: SSH setup failed (line $LINENO)"; exit 1002' ERR
[[ $(id -u) == 0 ]] || { echo 'CRITICAL: Root required'; exit 1002; }
[[ $(uname -s) == Linux ]] || { echo 'WARNING: Ubuntu Linux required'; exit 1001; }
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID%%.*} -ge 22 ]] || { echo 'WARNING: Ubuntu 22.04+ required'; exit 1001; }
[[ -d /run/systemd/system ]] || { echo 'WARNING: Running systemd required to enable SSH; no changes made'; exit 1001; }
if [[ $(dpkg-query -W -f='${Status}' openssh-server 2>/dev/null || true) != 'install ok installed' ]]; then
    apt-get -o APT::Update::Error-Mode=any update -qq
    apt-get -y -qq --no-remove -o Dpkg::Options::=--force-confold install openssh-server
fi
# Validate the real configuration (including existing custom ports) before startup.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
ports=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
[[ -n "$ports" ]] || { echo 'CRITICAL: No configured SSH ports'; exit 1002; }
systemctl enable --now ssh.service
systemctl is-enabled --quiet ssh.service
systemctl is-active --quiet ssh.service
for port in $ports; do
    [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { echo 'CRITICAL: Invalid configured SSH port'; exit 1002; }
    listeners=$(ss -H -ltn "sport = :$port")
    [[ -n "$listeners" ]] || { echo "CRITICAL: SSH service active but port $port is not listening"; exit 1002; }
    echo "OK: SSH enabled at boot and listening on TCP $port"
done
echo 'Existing SSH authentication rules, host keys and firewall policy preserved.'
echo 'Remote access still depends on firewall/network rules and valid login credentials; not tested from another host.'
