#!/usr/bin/env python3
"""Offline sandbox regression; real ZIP extraction, no host package/app changes."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'tasks/Install_MySQLWorkbench_linux.sh'
KEY = 'BCA43417C3B485DD128EC6D4B7B3B788A8D3785C'


def run_case(arch='arm64', bad_key=False, bad_signature=False, malicious=None,
             conflict=False, rerun=False, unsafe_apt=False, distro='ubuntu', version='24.04', unsafe_parent=False,
             wrong_version=False, wrong_arch=False, missing_lib=False, oversized=False, tamper=False):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / 'etc').mkdir()
        (root / 'etc/os-release').write_text(f'ID={distro}\nVERSION_ID={version}\n')
        (root / 'etc/ssl/certs').mkdir(parents=True)
        (root / 'etc/ssl/certs/ca-certificates.crt').write_text('sandbox')
        (root / 'bin').mkdir()
        archive = root / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for name, data, mode in [
                ('mysql-workbench', b'\x7fELF\x02\x01' + b'\0' * 12 + (b'\xb7\0' if arch == 'arm64' and not wrong_arch else b'>\0'), 0o100755),
                ('resources/app/shell/bin/mysqlsh', b'\x7fELF\x02\x01' + b'\0' * 12 + (b'\xb7\0' if arch == 'arm64' else b'>\0'), 0o100755),
                ('resources/app/package.json', json.dumps({'name': 'mysql-workbench', 'version': '8.0.0' if wrong_version else '26.10.0'}).encode(), 0o100644),
            ]:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, data)
            if malicious:
                name, mode = malicious
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, b'bad')
            if oversized:
                for i in range(20001):
                    z.writestr(f'entry-{i}', b'')
        fake = '''#!/bin/bash
printf '%s %s\\n' "${0##*/}" "$*" >> "$LOG"
case "${0##*/}" in
id) echo 0 ;;
uname) echo Linux ;;
dpkg) if [ "$1" = --compare-versions ]; then python3 -c 'import sys; a,b=map(float,(sys.argv[1],sys.argv[3])); sys.exit(not (a >= b if sys.argv[2] == "ge" else a < b))' "$2" "$3" "$4"; else echo "$ARCH"; fi ;;
dpkg-query) exit 1 ;;
curl) url=''; out=''; while [ "$#" -gt 0 ]; do case "$1" in https:*) url=$1 ;; -o) shift; out=$1 ;; esac; shift; done
 case "$url" in *.zip) cp "$FIXTURE" "$out" ;; *) printf 'signature/key' > "$out" ;; esac ;;
gpg) if [[ " $* " = *' --show-keys '* ]]; then echo "fpr:::::::::$FINGERPRINT:"
 elif [[ " $* " = *' --verify '* ]]; then [ "$BAD_SIGNATURE" = no ] || exit 1; echo "[GNUPG:] VALIDSIG $FINGERPRINT 2026-10-01 0 0 4 0 1 10 00 $FINGERPRINT"; fi ;;

apt-get) if [[ " $* " = *' --simulate '* ]] && [ "$UNSAFE_APT" = yes ]; then echo 'Inst mysql-server (9 Oracle)'; fi ;;
ldd) if [ "$MISSING_LIB" = yes ]; then echo 'libgtk-3.so.0 => not found'; else echo 'libc.so.6 => /lib/libc.so.6 (0x1)'; fi ;;
*) exit 98 ;;
esac
'''
        for command in ['id', 'uname', 'dpkg', 'dpkg-query', 'curl', 'gpg', 'apt-get', 'ldd']:
            p = root / 'bin' / command
            p.write_text(fake)
            p.chmod(0o755)
        for directory in ['opt', 'usr/local/bin', 'usr/bin', 'usr/share/applications']:
            (root / directory).mkdir(parents=True, exist_ok=True)
        if conflict:
            (root / 'usr/local/bin/mysql-workbench').write_text('unmanaged - preserve me')
        source = SCRIPT.read_text()
        for prefix in ['/etc/os-release', '/etc/ssl/certs/ca-certificates.crt', '/opt/mysql-workbench', '/usr/local/bin', '/usr/bin/mysql-workbench', '/usr/share/applications']:
            source = source.replace(prefix, str(root) + prefix)
        # Only the sandbox's ancestors are checked, not the host's private temp directory.
        source = source.replace('path.parents', f'[p for p in path.parents if str(p).startswith({str(root)!r})]')
        target = root / 'task.sh'
        target.write_text(source)
        env = dict(os.environ, PATH=f'{root}/bin:/usr/bin:/bin', LOG=str(root / 'log'),
                   ARCH=arch, FIXTURE=str(archive), FINGERPRINT='BAD' if bad_key else KEY,
                   BAD_SIGNATURE='yes' if bad_signature else 'no', UNSAFE_APT='yes' if unsafe_apt else 'no',
                   MISSING_LIB='yes' if missing_lib else 'no', TMPDIR=temp)
        result = subprocess.run(['bash', str(target)], text=True, capture_output=True, env=env)
        app = root / 'opt/mysql-workbench/26.10.0/mysql-workbench'
        if result.returncode == 0:
            assert app.exists(), (result.stdout, result.stderr, (root / 'log').read_text())
            assert app.read_bytes().startswith(b'\x7fELF')
            assert stat.S_IMODE(app.stat().st_mode) == 0o755
            assert stat.S_IMODE(app.parent.stat().st_mode) == 0o755
            assert (root / 'usr/share/applications/mysql-workbench.desktop').is_file()
            if rerun or unsafe_parent or tamper:
                before = app.stat().st_mtime_ns
                if unsafe_parent:
                    app.parent.parent.chmod(0o777)
                if tamper:
                    (app.parent / 'resources/app/package.json').write_text('modified user install')
                again = subprocess.run(['bash', str(target)], text=True, capture_output=True, env=env)
                if unsafe_parent:
                    assert again.returncode != 0, 'Must reject writable managed parent'
                    assert stat.S_IMODE(app.parent.parent.stat().st_mode) == 0o777
                elif tamper:
                    assert again.returncode != 0, 'Must preserve modified managed installation'
                    assert (app.parent / 'resources/app/package.json').read_text() == 'modified user install'
                else:
                    assert again.returncode == 0, again.stdout + again.stderr
                assert app.stat().st_mtime_ns == before
        elif conflict:
            assert (root / 'usr/local/bin/mysql-workbench').read_text() == 'unmanaged - preserve me'
        else:
            assert not app.exists(), 'Failure must not publish an app'
        return result.returncode, result.stdout + result.stderr, (root / 'log').read_text()


if __name__ == '__main__':
    for arch in ['arm64', 'amd64']:
        code, output, log = run_case(arch=arch, rerun=True)
        assert code == 0, (code, output, log)
        assert f'glibc2.28-{"aarch64" if arch == "arm64" else "x86_64"}.zip' in log
        assert '--verify' in log and '--show-keys' in log
        assert any(line.startswith('ldd ') and 'shell/bin/mysqlsh' in line for line in log.splitlines()), log
    print('PASS: pinned signed generic ZIP, both architectures, native artifacts, permissions, idempotent rerun')
    run_case(unsafe_parent=True)
    run_case(tamper=True)
    code, output, log = run_case(version='22.04')
    assert code == 0 and 'libgtk-3-0t64' not in log and 'libasound2t64' not in log, (output, log)
    for options in [dict(bad_key=True), dict(bad_signature=True), dict(conflict=True), dict(unsafe_apt=True),
                    dict(arch='ppc64el'), dict(distro='debian'), dict(version='20.04'), dict(wrong_version=True),
                    dict(wrong_arch=True), dict(missing_lib=True), dict(oversized=True)]:
        code, output, log = run_case(**options)
        assert code != 0, (options, output, log)
        if options.get('bad_key') or options.get('bad_signature'):
            assert 'ldd ' not in log and '--simulate' not in log, log
    print('PASS: key/signature rejection, unmanaged preservation, database transaction guard, OS/architecture guards')
    for entry in [('../escape', 0o100644), ('/absolute', 0o100644), ('dir/../../escape', 0o100644),
                  ('link', 0o120777), ('special', 0o010644), ('setuid', 0o104755), ('back\\slash', 0o100644)]:
        code, output, log = run_case(malicious=entry)
        assert code != 0 and 'Unsafe ZIP entry' in output and 'ldd ' not in log, (entry, code, output)
    print('PASS: ZIP traversal, absolute paths, symlinks, special files/bits, backslashes rejected before publication')
