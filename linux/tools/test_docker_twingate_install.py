#!/usr/bin/env python3
"""Safe stdlib sandbox: never runs real package, network or service commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['STATE']); s = json.loads(p.read_text())
c, a = Path(sys.argv[0]).name, sys.argv[1:]
s['calls'].append([c] + a)
def done(code=0, output=''):
    p.write_text(json.dumps(s)); print(output); sys.exit(code)
if c == 'uname': done(output='Linux')
if c == 'id': done(output=str(s.get('uid', 0)))
if c == 'dpkg': done(output='amd64')
if c == 'dpkg-query': done(0 if a[-1] in s['packages'] else 1, 'install ok installed' if a[-1] in s['packages'] else '')
if c == 'apt-cache': done(output=' docker-compose-plugin | 5.6.1-1 | https://download.docker.com/linux/ubuntu jammy/stable amd64 Packages\n docker-compose-plugin | 2.40.3-1 | https://download.docker.com/linux/ubuntu jammy/stable amd64 Packages')
if c == 'apt-get':
    if s.get('apt_fail'): done(1)
    if 'install' in a:
        for pkg in a[a.index('install')+1:]:
            if not pkg.startswith('-'): s['packages'].append(pkg.split('=')[0])
    done()
if c == 'curl':
    if s.get('download_fail'): done(22)
    Path(a[a.index('-o')+1]).write_text('sandbox signing key'); done()
if c == 'gpg':
    if s.get('bad_key'): done(2)
    if '--output' in a: Path(a[a.index('--output')+1]).write_text('sandbox keyring')
    done()
if c == 'systemctl':
    if s.get('service_fail'): done(1)
    if a[0] == 'is-active': done(0 if s.get('active') else 3)
    if 'start' in a or '--now' in a: s['active'] = True
    done()
if c == 'docker':
    if s.get('docker_fail') or 'docker-ce-cli' not in s['packages']: done(1)
    if 'compose' in a: done(0 if 'docker-compose-plugin' in s['packages'] and not s.get('compose_fail') else 1, s.get('compose_version', '2.40.3'))
    if 'info' in a: done(0 if s.get('active') else 1, '29.0.0')
    done(output='Docker version 29.0.0')
if c == 'twingate': done(0 if 'twingate' in s['packages'] and not s.get('version_fail') else 1, 'Twingate 2026.1')
done(99, 'unexpected command')
'''


def run(task, packages=(), **options):
    with tempfile.TemporaryDirectory(prefix='linux-install-', dir=os.environ.get('TMPDIR')) as tmp:
        d = Path(tmp)
        (d / 'bin').mkdir()
        (d / 'etc').mkdir()
        (d / 'etc/os-release').write_text(options.pop('release', 'ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\n'))
        state = dict(packages=list(packages), calls=[], **options)
        (d / 'state').write_text(json.dumps(state))
        stub = d / 'bin/stub'
        stub.write_text(STUB.replace('#!/usr/bin/env python3', '#!' + sys.executable, 1))
        stub.chmod(0o755)
        for name in ('uname', 'id', 'dpkg', 'dpkg-query', 'apt-cache', 'apt-get', 'curl', 'gpg', 'systemctl', 'docker', 'twingate'):
            (d / 'bin' / name).symlink_to(stub)
        source = ROOT / 'tasks' / ('Install_' + task + '_linux.sh')
        assert source.is_file(), 'missing installer: ' + str(source)
        text = source.read_text().replace('/etc/', str(d / 'etc') + '/').replace('/usr/share/keyrings', str(d / 'keyrings'))
        script = d / 'installer.sh'
        script.write_text(text)
        env = dict(os.environ, PATH=str(d / 'bin') + ':/usr/bin:/bin', STATE=str(d / 'state'), TMPDIR=tmp)
        result = subprocess.run(['/bin/bash', '-c', 'umask 077; exec /bin/bash "$1"', 'test', str(script)], env=env, text=True, capture_output=True)
        state = json.loads((d / 'state').read_text())
        files = {str(p.relative_to(d)): (p.read_text(), p.stat().st_mode & 0o777) for base in ('etc/apt', 'keyrings') for p in (d / base).rglob('*') if p.is_file()}
        assert not any(c[0] == 'apt-get' and any(x in c for x in ('remove', 'purge', 'autoremove')) for c in state['calls'])
        return result, state, files


def check(task, code, packages=(), **options):
    result, state, files = run(task, packages, **options)
    assert result.returncode == code % 256, (task, options, result.returncode, result.stdout, result.stderr)
    return state, files


if __name__ == '__main__':
    state, files = check('Docker', 0)
    assert {'docker-ce', 'docker-ce-cli', 'containerd.io', 'docker-compose-plugin'} <= set(state['packages'])
    assert any('docker-compose-plugin' in c for c in state['calls'])
    assert state['active']
    assert any('signed-by=' in body and 'download.docker.com' in body for body, _ in files.values())
    assert all(mode == 0o644 for _, mode in files.values()), files
    print('PASS: Docker fresh install uses signed repository, Compose plugin and readable artifacts')
    state, files = check('Twingate', 0)
    assert 'twingate' in state['packages']
    assert any('signed-by=' in body and 'https://packages.twingate.com/apt/ * *' in body for body, _ in files.values())
    assert all(mode == 0o644 for _, mode in files.values()), files
    assert not any(c[0] == 'twingate' and any(x in c for x in ('setup', 'start', 'login')) for c in state['calls'])
    print('PASS: Twingate signed installation without setup or credentials')
    docker_packages = ('docker-ce', 'docker-ce-cli', 'containerd.io', 'docker-buildx-plugin', 'docker-compose-plugin')
    for task, packages in (('Docker', docker_packages), ('Twingate', ('twingate',))):
        state, files = check(task, 0, packages, active=True)
        assert not files and not any(c[0] in ('apt-get', 'curl', 'gpg') for c in state['calls'])
        for release in ('ID=debian\nVERSION_ID=22.04\n', 'ID=ubuntu\nVERSION_ID=20.04\n', 'ID=ubuntu\nVERSION_ID=22.01\n', 'ID=ubuntu\nVERSION_ID=invalid\n'):
            state, files = check(task, 1001, release=release)
            assert not files and not any(c[0] == 'apt-get' for c in state['calls'])
        state, files = check(task, 1002, uid=501)
        assert not files and not any(c[0] == 'apt-get' for c in state['calls'])
        for failure in ('apt_fail', 'download_fail', 'bad_key'):
            state, files = check(task, 1002, **{failure: True})
            assert not files
    for pkg in ('docker.io', 'docker-compose', 'docker-compose-v2', 'docker-doc', 'docker-buildx', 'podman-docker', 'containerd', 'runc'):
        state, files = check('Docker', 1001, (pkg,))
        assert not files and not any(c[0] in ('apt-get', 'systemctl') for c in state['calls'])
    state, files = check('Twingate', 1001, ('twingate-latest',))
    assert not files and not any(c[0] == 'apt-get' for c in state['calls'])
    state, files = check('Docker', 0, docker_packages, active=False)
    assert state['active'] and not files and not any(c[0] == 'apt-get' for c in state['calls'])
    for failure in ('docker_fail', 'compose_fail', 'service_fail'):
        check('Docker', 1002, **{failure: True})
    check('Docker', 0, docker_packages, active=True, compose_version='5.6.1')
    check('Docker', 1001, docker_packages, active=True, compose_version='1.29.2')
    check('Twingate', 1002, version_fail=True)
    check('Twingate', 1002, ('twingate',), version_fail=True)
    print('PASS: idempotence, OS/root guards, conflicts, failed keys/downloads/APT/CLI/service')
