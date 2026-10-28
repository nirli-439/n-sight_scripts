#!/usr/bin/env python3
"""Safe fixtures only; run with python3 linux/tools/test_ai_tool_install.py."""
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).with_name('Install_AI_Tool_linux.sh')


def shell(code, home, **env):
    return subprocess.run(['bash', '-c', 'set -eu; source "$1"; ' + code, '_', str(SCRIPT)],
                          env={**os.environ, 'HOME': str(home), **env}, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main():
    with tempfile.TemporaryDirectory(prefix='ai-install-', dir=os.environ.get('TMPDIR')) as tmp:
        home = Path(tmp)
        bins = home / 'bin'
        bins.mkdir()
        timeout = bins / 'timeout'
        timeout.write_text('#!/bin/sh\nshift\nexec "$@"\n')
        timeout.chmod(0o755)
        os.environ['PATH'] = f'{bins}:/usr/bin:/bin'
        fixture = home / 'installer'
        redirect_stub = '''curl() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then shift; printf '#!/bin/sh\\n' > "$1"; fi
        shift
    done
    printf '%s' "$FINAL_URL"
}
'''
        for url, final in [('https://claude.ai/install.sh', 'https://downloads.claude.ai/claude-code-releases/bootstrap.sh'),
                           ('https://chatgpt.com/codex/install.sh', 'https://releases.openai.com/codex/install.sh')]:
            result = shell(redirect_stub + f'ai_download {url} "$HOME/native.sh"', home, FINAL_URL=final)
            assert result.returncode == 0, result.stdout
            result = shell(redirect_stub + f'ai_download {url} "$HOME/native.sh"', home, FINAL_URL='https://evil.invalid/install.sh')
            assert result.returncode != 0, 'untrusted installer redirect accepted'
        fixture.write_text('''#!/bin/sh
set -eu
[ "$CODEX_NON_INTERACTIVE" = 1 ]
[ "$CODEX_INSTALL_DIR" = "$HOME/.local/bin" ]
mkdir -p "$CODEX_INSTALL_DIR"
printf '#!/bin/sh\\n[ "$1" = --version ] || exit 99\\necho codex-cli 1.2.3\\n' > "$CODEX_INSTALL_DIR/codex"
chmod +x "$CODEX_INSTALL_DIR/codex"
echo installed >> "$HOME/calls"
''')
        code = '''work=$(mktemp -d "$HOME/work.XXXXXX"); trap 'rm -rf "$work"' EXIT
ai_download() { [ "$1" = https://chatgpt.com/codex/install.sh ]; cp "$HOME/installer" "$2"; }
ai_install_native codex
ai_install_native codex
'''
        result = shell(code, home)
        assert result.returncode == 0, result.stdout
        assert (home / 'calls').read_text() == 'installed\n', result.stdout
        for name in ['.codex/auth.json', '.claude/settings.json', '.config/Antigravity/account']:
            path = home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('preserve')
        fixture.write_text('''#!/bin/bash
set -eu
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\\n[ "$1" = --version ] || exit 99\\necho "2.1.0 (Claude Code)"\\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
echo claude >> "$HOME/calls"
''')
        result = shell(code.replace('https://chatgpt.com/codex/install.sh', 'https://claude.ai/install.sh').replace('ai_install_native codex', 'ai_install_native claude'), home)
        assert result.returncode == 0, result.stdout
        assert (home / 'calls').read_text() == 'installed\nclaude\n'
        for name in ['.codex/auth.json', '.claude/settings.json', '.config/Antigravity/account']:
            assert (home / name).read_text() == 'preserve'
        (home / '.local/bin/claude').write_text('#!/bin/sh\nexit 17\n')
        result = shell('ai_install_native claude', home)
        assert result.returncode != 0 and 'preserved' in result.stdout, result.stdout
        (home / '.local/bin/claude').unlink()
        result = shell('work="$HOME"; ai_download() { return 22; }; ai_install_native claude', home)
        assert result.returncode != 0 and not (home / '.local/bin/claude').exists()
        result = shell('ai_main invalid', home)
        assert result.returncode != 0 and 'Unknown AI tool' in result.stdout
    print('PASS: native Claude/Codex installers, noninteractive/version/idempotence, preserve auth/settings, fail closed')
    test_desktop()


def test_desktop():
    import io
    import json
    import struct
    import tarfile
    from typing import Any
    source = SCRIPT.read_text().split("<<'PY_ANTIGRAVITY'\n", 1)
    assert len(source) == 2, 'Desktop installer missing'
    ns: dict[str, Any] = {'__name__': 'fixture'}
    exec(compile(source[1].split('\nPY_ANTIGRAVITY', 1)[0], str(SCRIPT), 'exec'), ns)
    url = 'https://storage.googleapis.com/antigravity-public/antigravity-hub/2.28.0-123/linux-x64/Antigravity.tar.gz'
    html = f'<a href="{url}" data-hub-platform="linux-x64">x64</a>'
    assert ns['release'](html, 'x64') == (url, '2.28.0-123')
    for bad in [url.replace('https:', 'http:'), url.replace('storage.googleapis.com/', 'storage.googleapis.com.evil/'), url.replace('antigravity-hub/', 'other/')]:
        try:
            ns['release'](html.replace(url, bad), 'x64')
            raise AssertionError('Untrusted metadata accepted')
        except ValueError:
            pass
    assert ns['crc32c'](io.BytesIO(b'123456789')) == '4waSgw=='
    with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
        root = Path(tmp)
        scope_home = root / 'scope-home'
        (scope_home / '.local/share').mkdir(parents=True)
        (scope_home / '.local/share/antigravity').symlink_to(root / 'outside')
        try:
            ns['locations'](scope_home)
            raise AssertionError('Out-of-home install path accepted')
        except ValueError:
            pass
        package = json.dumps({'name': 'antigravity', 'productName': 'Antigravity', 'version': '2.28.0'}).encode()
        header = json.dumps({'files': {'package.json': {'size': len(package), 'offset': '0'}}}).encode()
        header += b' ' * ((-len(header)) % 4)
        asar = struct.pack('<IIII', 4, 8 + len(header), 4 + len(header), len(header)) + header + package
        elf = bytearray(64)
        elf[:6] = b'\x7fELF\x02\x01'
        elf[18:20] = struct.pack('<H', 62)
        archive = root / 'app.tar.gz'
        def make(extra=None):
            with tarfile.open(archive, 'w:gz') as tar:
                for name, data, mode in [('Antigravity-x64/antigravity', elf, 0o755), ('Antigravity-x64/resources/app.asar', asar, 0o644)]:
                    member = tarfile.TarInfo(name)
                    member.size, member.mode = len(data), mode
                    tar.addfile(member, io.BytesIO(data))
                if extra:
                    tar.addfile(extra, io.BytesIO(b'x') if extra.size else None)
        make()
        ns['verify_download'](archive, {'x-goog-hash': 'crc32c=' + ns['crc32c'](io.BytesIO(archive.read_bytes()))})
        for headers in [{}, {'x-goog-hash': 'crc32c=AAAAAAAA'}]:
            try:
                ns['verify_download'](archive, headers)
                raise AssertionError('Unverified download accepted')
            except ValueError:
                pass
        stage = root / 'stage'
        stage.mkdir()
        app = ns['unpack'](archive, stage, 'x64')
        assert ns['app_version'](app, 'x64') == '2.28.0'
        for member in [tarfile.TarInfo('../escape'), tarfile.TarInfo('/absolute'), tarfile.TarInfo('Antigravity-x64/link')]:
            if member.name.endswith('link'):
                member.type, member.linkname = tarfile.SYMTYPE, '/outside'
            make(member)
            try:
                ns['unpack'](archive, root / 'bad', 'x64')
                raise AssertionError('Unsafe archive accepted')
            except ValueError:
                pass
        make()
        install_home = root / 'install-home'
        install_home.mkdir()
        work = root / 'work'
        work.mkdir()
        from unittest.mock import patch
        def fetch_fixture(requested, target):
            if requested == ns['PAGE']:
                target.write_text(html)
            else:
                assert requested == url
                target.write_bytes(archive.read_bytes())
            return {'x-goog-hash': 'crc32c=' + ns['crc32c'](io.BytesIO(target.read_bytes()))}
        ns['fetch'] = fetch_fixture
        with patch('sys.argv', ['installer', str(install_home), str(work), 'x86_64']), patch('subprocess.run', return_value=subprocess.CompletedProcess(['ldd'], 0, '', '')):
            ns['install']()
            ns['fetch'] = lambda *_: (_ for _ in ()).throw(AssertionError('Idempotent install downloaded again'))
            ns['install']()
        with tarfile.open(archive, 'w:gz') as tar:
            member = tarfile.TarInfo('Antigravity-arm64/antigravity')
            member.size, member.mode = len(elf), 0o755
            tar.addfile(member, io.BytesIO(elf))
        assert ns['unpack'](archive, root / 'arm-stage', 'arm').name == 'Antigravity-arm64'
        destination = root / 'home with spaces'
        destination.mkdir()
        ns['publish'](app, destination, '2.28.0-123', 'x64')
        entry = destination / '.local/share/applications/antigravity.desktop'
        assert entry.is_file() and 'Exec="' in entry.read_text()
        assert (destination / '.local/bin/antigravity').is_symlink()
        assert ns['installed'](destination, 'x64') == '2.28.0'
        original_entry = entry.read_text()
        entry.write_text(original_entry.replace('Exec=', 'BrokenExec='))
        try:
            ns['installed'](destination, 'x64')
            raise AssertionError('Broken desktop launcher accepted')
        except ValueError:
            pass
        entry.write_text(original_entry)
        (destination / '.local/share/antigravity/2.28.0-123/antigravity').write_text('corrupt')
        try:
            ns['installed'](destination, 'x64')
            raise AssertionError('Corrupt existing app accepted')
        except ValueError:
            pass
    print('PASS: desktop metadata trust, CRC32C, safe extraction, app version/ELF, desktop entry, idempotence/corruption')


if __name__ == '__main__':
    main()
