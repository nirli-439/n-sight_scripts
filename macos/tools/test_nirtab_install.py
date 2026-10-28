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
defaults() { if [[ "$CASE" == invalid_existing ]]; then echo unrelated; else echo com.nir.nirtab; fi; }
codesign() { [[ "$CASE" != bad_signature ]]; }
ditto() {
    if [[ "$1" == -x ]]; then mkdir -p "$4/NirTab.app/Contents"; else /usr/bin/ditto "$@"; fi
}
'''
for case in ('existing', 'invalid_existing', 'fresh', 'download_fail', 'bad_hash', 'bad_signature'):
    with tempfile.TemporaryDirectory(prefix='nirtab-test-') as temp:
        target = Path(temp) / 'Applications/NirTab.app'
        target.parent.mkdir()
        if case in ('existing', 'invalid_existing'):
            target.mkdir()
            (target/'sentinel').write_text('keep')
        code = source.replace('/Applications/NirTab.app', str(target))
        code = code.replace('[[ $EUID -eq 0 ]] || fail "Run as root (sudo)"', ':')
        result = subprocess.run(['/bin/bash'], input=stubs+code, text=True,
                                capture_output=True, env=dict(os.environ, CASE=case, TMPDIR=temp))
        assert result.returncode == (0 if case in ('fresh','existing') else 234), (case,result.stdout,result.stderr)
        if case in ('existing','invalid_existing'):
            assert (target/'sentinel').read_text() == 'keep'
        else:
            assert target.exists() == (case == 'fresh'), case
print('PASS: NirTab syntax, existing/fresh install, preservation, failed download/hash/signature guards')
