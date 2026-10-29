#!/usr/bin/env python3
"""Sandbox only: package/firmware commands are stubs; no real host changes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import fcntl
import pty
import select
import termios
import time

TASK = Path(__file__).resolve().parents[1] / 'tasks/Update_System_Firmware_linux.sh'
STUB = '''#!PYTHON
import json, os, sys
from pathlib import Path
p=Path(os.environ['STATE']); s=json.loads(p.read_text()); c=Path(sys.argv[0]).name; a=sys.argv[1:]
s['calls'].append([c]+a); p.write_text(json.dumps(s))
def done(rc=0, text=''): print(text); sys.exit(rc)
if c=='id': done(text='0')
if c=='uname': done(text='Linux')
if c=='apt-get':
    if 'update' in a and s.get('apt_fail'): done(100)
    if 'upgrade' in a and s.get('upgrade_fail'): done(100)
    done()
if c=='apt-mark': done(text=s.get('held',''))
if c=='apt': done(text='Listing...\\n'+s.get('pending',''))
if c=='fwupdmgr':
    if '--help' in a: done(text='--no-reboot-check --no-unreported-check --no-remote-check --json --assume-yes')
    if 'get-devices' in a: done(text=s.get('devices',json.dumps({'Devices':[{'Flags':['supported','updatable']}]})))
    if 'get-updates' in a: done(s.get('fw_rc',2), 'Device: Test BIOS -> 2.0' if s.get('fw_rc',2)==0 else 'No applicable upgrades')
    if 'refresh' in a: done(s.get('refresh_rc',0))
    if 'update' in a: done(s.get('flash_rc',0))
    done()
done(99, 'unexpected command: '+c)
'''


def run(expected, **options):
    assert TASK.exists(), 'missing system/firmware task'
    with tempfile.TemporaryDirectory(prefix='firmware-test-', dir=os.environ.get('TMPDIR')) as tmp:
        d=Path(tmp); (d/'bin').mkdir(); (d/'etc').mkdir(); (d/'run').mkdir(); (d/'power').mkdir()
        (d/'etc/os-release').write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        if options.pop('reboot',False): (d/'run/reboot-required').touch()
        battery=options.pop('battery',False)
        if battery:
            (d/'power/BAT0').mkdir(); (d/'power/BAT0/type').write_text('Battery'); (d/'power/BAT0/status').write_text(battery)
        if options.pop('ac',False):
            (d/'power/AC').mkdir(); (d/'power/AC/type').write_text('Mains'); (d/'power/AC/online').write_text('1')
        answer=options.pop('answer',None)
        expect_flash=options.pop('expect_flash',False)
        (d/'state').write_text(json.dumps(dict(calls=[],**options)))
        stub=d/'bin/stub'; stub.write_text(STUB.replace('PYTHON',sys.executable,1)); stub.chmod(0o755)
        for c in ('id','uname','apt-get','apt-mark','apt','fwupdmgr'): (d/'bin'/c).symlink_to(stub)
        source=TASK.read_text().replace('/etc/',str(d/'etc')+'/').replace('/run/',str(d/'run')+'/').replace('/sys/class/power_supply',str(d/'power'))
        script=d/'task.sh'; script.write_text(source)
        env=dict(os.environ,PATH=str(d/'bin')+':/usr/bin:/bin',STATE=str(d/'state'),TMPDIR=tmp)
        if answer is None:
            result=subprocess.run(['/bin/bash',str(script)],env=env,input='APPLY FIRMWARE\n',capture_output=True,text=True,start_new_session=True,timeout=30)
        else:
            master,slave=pty.openpty()
            def controlling_tty():
                os.setsid(); fcntl.ioctl(slave,termios.TIOCSCTTY,0)
            proc=subprocess.Popen(['/bin/bash',str(script)],env=env,stdin=slave,stdout=slave,stderr=slave,preexec_fn=controlling_tty)
            os.close(slave); output=b''; sent=False; deadline=time.monotonic()+30
            try:
                while time.monotonic()<deadline:
                    if select.select([master],[],[],0.1)[0]:
                        try: chunk=os.read(master,65536)
                        except OSError: break
                        if not chunk: break
                        output+=chunk
                        if b'Type APPLY FIRMWARE' in output and not sent:
                            os.write(master,(answer+'\n').encode()); sent=True
                    elif proc.poll() is not None: break
                try: proc.wait(timeout=max(0.1,deadline-time.monotonic()))
                except subprocess.TimeoutExpired:
                    proc.kill(); raise AssertionError('PTY test timed out')
                result=subprocess.CompletedProcess(proc.args,proc.returncode,output.decode(), '')
            finally:
                os.close(master)
        s=json.loads((d/'state').read_text()); calls=s['calls']
        assert result.returncode==expected%256,(options,result.returncode,result.stdout,result.stderr)
        assert any(c[0]=='fwupdmgr' and 'update' in c for c in calls)==expect_flash, calls
        assert not any(x in c for c in calls for x in ('purge','remove','autoremove','full-upgrade','dist-upgrade','--no-safety-check'))
        return result.stdout,calls


if __name__=='__main__':
    out,calls=run(1002,apt_fail=True)
    assert 'CRITICAL' in out
    assert any(c[0]=='apt-get' and 'update' in c for c in calls)
    print('PASS: APT failure stays critical')
    out,calls=run(0)
    upgrade=next(c for c in calls if c[0]=='apt-get' and 'upgrade' in c)
    assert '--with-new-pkgs' in upgrade and '--no-remove' in upgrade and 'Dpkg::Options::=--force-confold' in upgrade
    assert '--json' in next(c for c in calls if c[0]=='fwupdmgr' and 'enable-remote' in c)
    for options in ({'pending':'foo/stable 2 amd64 [upgradable from: 1]'}, {'held':'foo'}, {'reboot':True}, {'fw_rc':3}, {'refresh_rc':2}, {'fw_rc':0}):
        run(1001,**options)
    run(1001,fw_rc=0,answer='no')
    run(1001,fw_rc=0,answer='APPLY FIRMWARE',expect_flash=True)
    run(1002,fw_rc=0,flash_rc=1,answer='APPLY FIRMWARE',expect_flash=True)
    out,calls=run(1002,fw_rc=0,apt_fail=True,answer='APPLY FIRMWARE')
    assert not any(c[0]=='fwupdmgr' for c in calls), 'Firmware must not proceed after failed APT refresh'
    out,calls=run(1002,fw_rc=0,upgrade_fail=True,answer='APPLY FIRMWARE')
    assert not any(c[0]=='fwupdmgr' for c in calls), 'Firmware must not proceed after failed OS upgrade'
    for status in ('Discharging','Unknown','Not charging','Full'):
        run(1001,fw_rc=0,battery=status,answer='APPLY FIRMWARE')
    run(1001,fw_rc=0,battery='Full',ac=True,answer='APPLY FIRMWARE',expect_flash=True)
    run(1001,fw_rc=0,battery='Discharging',ac=True,answer='APPLY FIRMWARE')
    for devices in ('{}','invalid',json.dumps({'Devices':[{'Flags':['updatable']}]})):
        run(1001,devices=devices)
    for state in (1,4,'pending','needs-reboot'):
        run(1001,devices=json.dumps({'Devices':[{'Flags':['supported','updatable'],'UpdateState':state}]}))
    print('PASS: activation pending cannot report fully up-to-date')
    print('PASS: safe upgrade, pending/held/reboot, fwupd rc 2/3, metadata failure, headless/declined/confirmed PTY, battery guards')
