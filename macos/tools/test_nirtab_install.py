#!/usr/bin/env python3
"""NirTab install sandbox: no downloads, privileges or actual /Applications writes."""
from pathlib import Path
import os
import subprocess
import tempfile

path = Path(__file__).resolve().parents[1] / 'tasks/Install_NirTab_mac.sh'
assert path.exists(), 'NirTab installer missing'
source = path.read_text()
subprocess.run(['/bin/bash', '-n', str(path)], check=True)
assert 'spctl --master-disable' not in source and 'xattr' not in source
stubs = '''
sw_vers() { echo 15.0; }
curl() { [[ "$CASE" != download_fail ]]; }
shasum() { /bin/cat >/dev/null; [[ "$CASE" != bad_hash ]]; }
defaults() { if [[ "$CASE" == invalid_existing ]]; then echo unrelated; elif [[ "$3" == CFBundleExecutable ]]; then echo NirTab; else echo com.nir.nirtab; fi; }
codesign() { [[ "$CASE" != bad_signature ]]; }
ditto() {
    if [[ "$1" == -x ]]; then
        mkdir -p "$4/NirTab.app/Contents/MacOS"
        if [[ "$CASE" != missing_exec ]]; then
            printf '#!/bin/sh\nexit 0\n' > "$4/NirTab.app/Contents/MacOS/NirTab"
            chmod 700 "$4/NirTab.app/Contents/MacOS/NirTab"
        fi
    else /usr/bin/ditto "$@"; fi
}
'''
for case in ('existing', 'invalid_existing', 'fresh', 'download_fail', 'bad_hash', 'bad_signature', 'missing_exec'):
    with tempfile.TemporaryDirectory(prefix='nirtab-test-') as temp:
        target = Path(temp) / 'Applications/NirTab.app'
        target.parent.mkdir()
        if case in ('existing', 'invalid_existing'):
            target.mkdir(mode=0o700)
            (target/'sentinel').write_text('keep')
            executable=target/'Contents/MacOS/NirTab'
            executable.parent.mkdir(parents=True, mode=0o700)
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o700)
        code = source.replace('/Applications/NirTab.app', str(target))
        code = code.replace('[[ $EUID -eq 0 ]] || fail "Run as root (sudo)"', ':')
        result = subprocess.run(['/bin/bash'], input='umask 077\n'+stubs+code, text=True,
                                capture_output=True, env=dict(os.environ, CASE=case, TMPDIR=temp))
        assert result.returncode == (0 if case in ('fresh','existing') else 234), (case,result.stdout,result.stderr)
        if case in ('fresh', 'existing'):
            assert target.stat().st_mode & 0o005 == 0o005, (case, 'app not traversable by other users')
            for item in target.rglob('*'):
                required=0o005 if item.is_dir() or item.name=='NirTab' else 0o004
                assert item.stat().st_mode & required == required, (case, item, oct(item.stat().st_mode))
        if case in ('existing','invalid_existing'):
            assert (target/'sentinel').read_text() == 'keep'
        else:
            assert target.exists() == (case == 'fresh'), case
print('PASS: NirTab syntax, existing/fresh install, preservation, failed download/hash/signature guards')
