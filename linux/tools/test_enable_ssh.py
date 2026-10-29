#!/usr/bin/env python3
"""Sandbox SSH service checks; no real host package/service/firewall changes."""
from pathlib import Path
import os
import subprocess
import tempfile

script=Path(__file__).resolve().parents[1]/'tasks/Enable_SSH_linux.sh'
assert script.exists(), 'SSH task missing'
source=script.read_text()
subprocess.run(['/bin/bash','-n',str(script)],check=True)
for case in ('existing','fresh','bad_config','service_fail','not_listening','not_systemd'):
    with tempfile.TemporaryDirectory(prefix='ssh-task-') as temp:
        root=Path(temp);(root/'os-release').write_text('ID=ubuntu\nVERSION_ID=24.04\n')
        events=root/'events';events.touch()
        stubs='''
id() { echo 0; }
uname() { echo Linux; }
dpkg-query() { [[ "$CASE" != fresh ]] && echo 'install ok installed'; }
apt-get() { echo "apt $*" >> "$EVENTS"; }
sshd() {
    echo "sshd $*" >> "$EVENTS"
    [[ "$CASE" != bad_config ]] || return 1
    [[ "$1" != -T ]] || printf 'port 2222\\npasswordauthentication no\\n'
}
systemctl() { echo "service $*" >> "$EVENTS"; [[ "$CASE" != service_fail ]]; }
ss() { [[ "$CASE" != not_listening ]] && echo 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*'; }
ufw() { echo 'FAIL: firewall changed'; exit 99; }
'''
        code=source.replace('/etc/os-release',str(root/'os-release')).replace('/run/systemd/system',str(root/'systemd'))
        if case!='not_systemd':(root/'systemd').mkdir()
        code=code.replace('/usr/sbin/sshd','sshd').replace('/run/sshd',str(root/'sshd'))
        r=subprocess.run(['/bin/bash'],input=stubs+code,text=True,capture_output=True,env=dict(os.environ,CASE=case,EVENTS=str(events)))
        expected=0 if case in ('fresh','existing') else 233 if case=='not_systemd' else 234
        assert r.returncode==expected,(case,r.returncode,r.stdout,r.stderr)
        calls=events.read_text()
        if case=='bad_config':assert 'service enable' not in calls
        if case=='existing':assert 'apt ' not in calls
        if case=='fresh':assert 'openssh-server' in calls
        assert '2222' in r.stdout or expected!=0
assert 'PasswordAuthentication' not in source and 'PermitRootLogin' not in source
print('PASS: install/idempotence, config validated before start, startup/listener failures, systemd guard, custom port, auth/firewall preserved')
