#!/usr/bin/env python3
"""Existing Bitdefender must not claim success while bdsec is stopped."""
from pathlib import Path
import os
import subprocess
import tempfile
source=(Path(__file__).resolve().parents[1]/'tasks/Install_Bitdefender_linux.sh').read_text()
with tempfile.TemporaryDirectory(prefix='bitdefender-test-') as temp:
    code=source.replace('readonly LOG_DIR="/var/log/nsight"',f'readonly LOG_DIR="{temp}"')
    code=code.replace('if [[ $EUID -ne 0 ]]; then','if false; then')
    stub='''
dpkg-query() { echo 'install ok installed'; }
systemctl() { [[ "$CASE" == active ]]; }
'''
    for case in ('active','stopped'):
        r=subprocess.run(['/bin/bash'],input=stub+code,text=True,capture_output=True,env=dict(os.environ,CASE=case))
        assert r.returncode==(0 if case=='active' else 233),(case,r.returncode,r.stdout,r.stderr)
print('PASS: registered Bitdefender package succeeds only when daemon active; stopped service is a warning')
