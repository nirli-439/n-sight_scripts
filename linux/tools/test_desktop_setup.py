#!/usr/bin/env python3
"""Sandbox Slack + GNOME policy files. Never install packages/change real /etc."""
from pathlib import Path
import os
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
slack=root/'tasks/Install_Slack_linux.sh'
assert slack.exists(), 'Slack Linux installer missing'
with tempfile.TemporaryDirectory(prefix='linux-desktop-test-') as temp:
    tmp=Path(temp)
    source=slack.read_text().replace('[[ $EUID -eq 0 ]] || fail "Root privileges required"', ':')
    source=source.replace('/usr/local',str(tmp/'usr/local')).replace('/var/lib/flatpak',str(tmp/'flatpak'))
    desktop=tmp/'flatpak/exports/share/applications/com.slack.Slack.desktop'
    desktop.parent.mkdir(parents=True);desktop.write_text('[Desktop Entry]\nName=Slack\n')
    stub='''
flatpak() { if [[ "$1" == info ]]; then echo flathub; fi; }
update-desktop-database() { :; }
'''
    result=subprocess.run(['/bin/bash'],input='umask 077\n'+stub+source,text=True,capture_output=True)
    assert result.returncode==0,(result.stdout,result.stderr)
    assert (tmp/'usr/local/share/applications/com.slack.Slack.desktop').read_text()==desktop.read_text()
    assert (tmp/'usr/local/bin/slack').stat().st_mode & 0o005==0o005
    assert (tmp/'usr/local/share/applications').stat().st_mode & 0o005==0o005
    task=(root/'tasks/Remediate_ScreenLock_Timeout_linux.sh').read_text()
    task=task.replace('if [[ $EUID -ne 0 ]]; then','if false; then').replace('/etc/dconf',str(tmp/'etc/dconf'))
    fake=tmp/'dconf';fake.write_text('#!/bin/sh\nexit 0\n');fake.chmod(0o755)
    task=task.replace('/usr/bin/dconf',str(fake))
    result=subprocess.run(['/bin/bash'],input='umask 077\n'+task,text=True,capture_output=True)
    assert result.returncode==0,(result.stdout,result.stderr)
    policy=tmp/'etc/dconf/db/local.d/00-screen-lock'
    assert 'idle-delay=uint32 900' in policy.read_text()
    assert policy.stat().st_mode & 0o004
    assert (tmp/'etc/dconf/db/local.d/locks/00-screen-lock').read_text().count('/org/gnome/')==3
    for item in (tmp/'etc/dconf').rglob('*'):
        assert item.stat().st_mode & (0o005 if item.is_dir() else 0o004)
print('PASS: Slack launcher/wrapper and locked GNOME 15-minute policy files are readable under umask 077; no real system changed')
