#!/usr/bin/env python3
"""Regression: installing/re-running Drive must not edit any user's Dock."""
from pathlib import Path
import re
import subprocess

script = Path(__file__).resolve().parents[1] / 'tasks/Install_GoogleDrive_mac.sh'
source = script.read_text()
subprocess.run(['/bin/bash', '-n', str(script)], check=True)
# Check executable lines, not documentation. Both onboarding paths use this file.
code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('#'))
for forbidden in ('add_to_dock', 'com.apple.dock', 'persistent-apps', 'killall Dock'):
    assert forbidden not in code, f'Drive setup still modifies the Dock: {forbidden}'
assert 'Dock: Added' not in source and 'Dock: Verified/Added' not in source
assert re.search(r'if check_googledrive_installed; then[\s\S]*?exit \$EXIT_SUCCESS', source)
assert 'verify_installation' in source and 'install_googledrive' in source
# Exercise both main branches with installer/system operations stubbed; no sudo,
# downloads, mounts, application changes or real user preferences are touched.
import tempfile
with tempfile.TemporaryDirectory(prefix='drive-regression-') as temp:
    prefix, main = source.split('# MAIN EXECUTION', 1)
    prefix = prefix.replace('readonly LOG_DIR="/var/log/nsight"', f'readonly LOG_DIR="{temp}"')
    for installed in (True, False):
        stubs = '''
log() { :; }
cleanup() { :; }
check_root() { :; }
get_macos_name() { echo macOS; }
get_macos_version() { echo test; }
sw_vers() { echo test; }
check_googledrive_installed() { return STATE; }
get_googledrive_version() { echo test; }
download_googledrive() { echo DOWNLOAD; }
mount_dmg() { echo MOUNT; }
install_googledrive() { echo INSTALL; }
verify_installation() { echo VERIFY; }
'''.replace('STATE', '0' if installed else '1')
        result = subprocess.run(['/bin/bash'], input=prefix + stubs + main,
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert 'Dock: Unchanged' in result.stdout, result.stdout
        assert ('INSTALL' in result.stdout) == (not installed)
        if not installed:
            assert all(step in result.stdout for step in ('DOWNLOAD', 'MOUNT', 'INSTALL', 'VERIFY'))
print('PASS: syntax, existing/fresh install flows, and no Dock writes/restarts/false claims')
