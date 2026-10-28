#!/bin/bash
# User-scoped Ubuntu 22.04+ onboarding. Run WITHOUT sudo as the technician:
# bash Install_AI_Tool_linux.sh claude-code|codex|antigravity
# Exit 0 = verified; 1 = error/blocker. Never logs in or starts an agent.
# Official native installers verify their own published payload checksums.
# Sources: code.claude.com/docs/en/quickstart; github.com/openai/codex;
# antigravity.google/download and /docs/getting-started (desktop, not agy/IDE).

ai_error() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

ai_download() {
    local final
    case "$1" in
        https://claude.ai/install.sh|https://chatgpt.com/codex/install.sh) ;;
        *) ai_error "Untrusted installer URL: $1"; return 1 ;;
    esac
    final=$(curl --fail --silent --show-error --location --proto '=https' \
        --proto-redir '=https' --connect-timeout 20 --max-time 180 \
        --output "$2" --write-out '%{url_effective}' "$1") || return 1
    [[ -s "$2" ]] || { ai_error 'Empty installer response'; return 1; }
    case "$1|$final" in
        'https://claude.ai/install.sh|https://claude.ai/install.sh'|\
        'https://claude.ai/install.sh|https://downloads.claude.ai/claude-code-releases/bootstrap.sh'|\
        'https://chatgpt.com/codex/install.sh|https://chatgpt.com/codex/install.sh'|\
        'https://chatgpt.com/codex/install.sh|https://releases.openai.com/codex/install.sh') return 0 ;;
        *) ai_error "Untrusted installer redirect: $final"; return 1 ;;
    esac
}

ai_version() {
    local output
    output=$(timeout 30 "$1" --version </dev/null 2>/dev/null) || return 1
    case "$2" in
        claude) [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+.*Claude\ Code ]] || return 1 ;;
        codex) [[ "$output" =~ ^codex-cli[[:space:]][0-9]+\.[0-9]+\.[0-9]+ ]] || return 1 ;;
    esac
    printf '%s\n' "$output"
}

ai_install_native() {
    local tool="$1" existing version url
    existing="$HOME/.local/bin/$tool"
    if [[ ! -e "$existing" && ! -L "$existing" ]]; then
        existing=$(command -v "$tool" || true)
    fi
    if [[ -n "$existing" ]]; then
        version=$(ai_version "$existing" "$tool") || { ai_error "Existing $tool failed version verification; preserved: $existing"; return 1; }
        printf 'Verified existing %s: %s (%s)\n' "$tool" "$version" "$existing"
        return 0
    fi
    case "$tool" in
        claude) url=https://claude.ai/install.sh ;;
        codex) url=https://chatgpt.com/codex/install.sh ;;
        *) ai_error 'Unknown native tool'; return 1 ;;
    esac
    ai_download "$url" "$work/install.sh" || return 1
    bash -n "$work/install.sh" || return 1
    if [[ "$tool" == codex ]]; then
        CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$HOME/.local/bin" \
            sh "$work/install.sh" </dev/null || return 1
    else
        bash "$work/install.sh" </dev/null || return 1
    fi
    version=$(ai_version "$HOME/.local/bin/$tool" "$tool") || { ai_error "$tool installed but version verification failed"; return 1; }
    printf 'Verified %s: %s. No login or agent launch requested.\n' "$tool" "$version"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf 'For this shell: export PATH="$HOME/.local/bin:$PATH"\n' ;; esac
}

ai_install_antigravity() {
    python3 - "$HOME" "$work" "$(uname -m)" <<'PY_ANTIGRAVITY'
import base64
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

PAGE = 'https://antigravity.google/download'
PATTERN = r'https://storage\.googleapis\.com/antigravity-public/antigravity-hub/(\d+\.\d+\.\d+-\d+)/linux-(x64|arm)/Antigravity\.tar\.gz'
MARKER = '# Managed by Install_AI_Tool_linux.sh'


def release(html, arch):
    class Links(HTMLParser):
        urls = []
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == 'a' and attrs.get('data-hub-platform') == 'linux-' + arch:
                self.urls.append(attrs.get('href', ''))
    parser = Links()
    parser.feed(html)
    urls = list(dict.fromkeys(parser.urls))
    if len(urls) != 1:
        raise ValueError('Official desktop download metadata missing/ambiguous; no CLI or IDE substitution')
    match = re.fullmatch(PATTERN, urls[0])
    if not match or match[2] != arch:
        raise ValueError('Untrusted desktop release URL')
    return urls[0], match[1]


class TrustedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, url):
        if url != PAGE and not re.fullmatch(PATTERN, url):
            raise ValueError('Untrusted HTTPS redirect: ' + url)
        return super().redirect_request(request, fp, code, msg, headers, url)


def fetch(url, destination):
    if url != PAGE and not re.fullmatch(PATTERN, url):
        raise ValueError('Untrusted download URL')
    with urllib.request.build_opener(TrustedRedirect()).open(url, timeout=60) as response:
        with destination.open('wb') as output:
            total = 0
            while True:
                data = response.read(1024 * 1024)
                if not data:
                    break
                total += len(data)
                if total > (8 * 1024**2 if url == PAGE else 1024**3):
                    raise ValueError('Download exceeds safety limit')
                output.write(data)
        return dict(response.headers)


def crc32c(stream):
    # GCS publishes CRC32C, not SHA256, for this composed object. TLS authenticates it.
    table = []
    for value in range(256):
        for _ in range(8):
            value = (value >> 1) ^ (0x82F63B78 if value & 1 else 0)
        table.append(value)
    crc = 0xffffffff
    while True:
        block = stream.read(1024 * 1024)
        if not block:
            break
        for byte in block:
            crc = table[(crc ^ byte) & 255] ^ (crc >> 8)
    return base64.b64encode(struct.pack('>I', crc ^ 0xffffffff)).decode()


def verify_download(archive, headers):
    headers = {k.lower(): v for k, v in headers.items()}
    hashes = dict(item.strip().split('=', 1) for item in headers.get('x-goog-hash', '').split(',') if '=' in item)
    if not hashes:
        raise ValueError('No published object checksum; refusing unverifiable download')
    for algorithm, expected in hashes.items():
        with archive.open('rb') as stream:
            if algorithm == 'crc32c':
                actual = crc32c(stream)
            elif algorithm in ('md5', 'sha256'):
                digest = hashlib.new(algorithm)
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
                actual = base64.b64encode(digest.digest()).decode()
            else:
                raise ValueError('Unknown published checksum: ' + algorithm)
        if actual != expected:
            raise ValueError('Desktop archive checksum mismatch: ' + algorithm)


def unpack(archive, stage, arch):
    root = 'Antigravity-' + {'x64': 'x64', 'arm': 'arm64'}[arch]
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        if len(members) > 10000 or sum(m.size for m in members) > 2 * 1024**3:
            raise ValueError('Archive exceeds safety limit')
        seen = set()
        for member in members:
            parts = PurePosixPath(member.name).parts
            if (not parts or parts[0] != root or '..' in parts or member.name.startswith('/')
                    or member.name in seen or not (member.isdir() or member.isfile())):
                raise ValueError('Unsafe archive path/type: ' + member.name)
            seen.add(member.name)
        # No links/devices, no archive ownership or special permission bits.
        stage.mkdir(parents=True, exist_ok=True)
        for member in members:
            target = stage / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return stage / root


def app_version(app, arch):
    binary = app / 'antigravity'
    with binary.open('rb') as stream:
        elf = stream.read(64)
    if (len(elf) < 64 or elf[:6] != b'\x7fELF\x02\x01'
            or struct.unpack('<H', elf[18:20])[0] != {'x64': 62, 'arm': 183}[arch]
            or not os.access(binary, os.X_OK)):
        raise ValueError('Desktop executable is not an executable native ELF for this architecture')
    # Electron's top-level "version" is Electron's version, not Antigravity's.
    # Read app.asar package metadata without ever launching the GUI/agent.
    with (app / 'resources/app.asar').open('rb') as stream:
        prefix = stream.read(16)
        _, header_size, _, json_size = struct.unpack('<IIII', prefix)
        if not 0 < json_size <= 32 * 1024**2 or header_size < json_size + 8:
            raise ValueError('Invalid app.asar header')
        header = json.loads(stream.read(json_size))
        package = header['files']['package.json']
        if not 0 < package['size'] < 65536 or int(package['offset']) < 0:
            raise ValueError('Invalid app package metadata')
        stream.seek(8 + header_size + int(package['offset']))
        metadata = json.loads(stream.read(package['size']))
    if (metadata.get('name') != 'antigravity' or metadata.get('productName') != 'Antigravity'
            or not re.fullmatch(r'\d+\.\d+\.\d+', metadata.get('version', ''))):
        raise ValueError('Not the official Antigravity desktop application')
    return metadata['version']


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def locations(home):
    data = Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
    if not data.is_absolute() or not data.resolve().is_relative_to(home.resolve()):
        raise ValueError('XDG_DATA_HOME must be inside the current user home')
    paths = home / '.local/share/antigravity', home / '.local/bin/antigravity', data / 'applications/antigravity.desktop'
    if any(not path.resolve().is_relative_to(home.resolve()) for path in paths):
        raise ValueError('Install paths must remain inside the current user home')
    return paths


def desktop_entry(binary):
    executable = str(binary).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
    return ('[Desktop Entry]\n' + MARKER + '\nType=Application\nName=Antigravity\n'
            + 'Comment=Google Antigravity desktop application\nExec="' + executable
            + '" %U\nIcon=application-x-executable\nTerminal=false\nCategories=Development;\n')


def installed(home, arch):
    root, binary, desktop = locations(home)
    if not (binary.exists() or binary.is_symlink() or desktop.exists()):
        return None
    if (not binary.is_symlink() or not desktop.is_file() or desktop.is_symlink()
            or desktop.read_text() != desktop_entry(binary) or not binary.resolve().is_relative_to(root.resolve())):
        raise ValueError('Existing unmanaged Antigravity launcher preserved; manual reconciliation required')
    app = binary.resolve().parent
    record = json.loads((app / '.onboarding.json').read_text())
    for name, expected in record['files'].items():
        file = app / name
        if not file.resolve().is_relative_to(app.resolve()) or file.is_symlink() or digest(file) != expected:
            raise ValueError('Existing desktop failed integrity verification; preserved')
    version = app_version(app, arch)
    if version != record['version']:
        raise ValueError('Existing desktop version mismatch; preserved')
    return version


def publish(app, home, build, arch):
    root, binary, desktop = locations(home)
    if not re.fullmatch(r'\d+\.\d+\.\d+-\d+', build):
        raise ValueError('Invalid build identifier')
    version = app_version(app, arch)
    if version != build.rsplit('-', 1)[0]:
        raise ValueError('Downloaded app version differs from official metadata')
    if binary.exists() or binary.is_symlink() or desktop.exists() or desktop.is_symlink():
        raise ValueError('Existing launcher preserved; refusing overwrite')
    record = {'version': version, 'files': {str(p.relative_to(app)): digest(p) for p in app.rglob('*') if p.is_file()}}
    (app / '.onboarding.json').write_text(json.dumps(record))
    root.mkdir(parents=True, exist_ok=True)
    binary.parent.mkdir(parents=True, exist_ok=True)
    desktop.parent.mkdir(parents=True, exist_ok=True)
    destination = root / build
    if destination.exists() or destination.is_symlink():
        raise ValueError('Unregistered destination already exists; preserved')
    # Work is staged under root on the same filesystem; rename is atomic.
    app.rename(destination)
    binary.symlink_to(destination / 'antigravity')
    # Exclusive create: never follow an existing desktop symlink or clobber it.
    with desktop.open('x') as output:
        output.write(desktop_entry(binary))
    desktop.chmod(0o644)
    if installed(home, arch) != version:
        raise ValueError('Published desktop verification failed')


def install():
    home, work, machine = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    arch = {'x86_64': 'x64', 'aarch64': 'arm', 'arm64': 'arm'}.get(machine)
    if not arch:
        raise ValueError('Unsupported desktop architecture: ' + machine)
    existing = installed(home, arch)
    if existing:
        print('Verified existing Antigravity desktop ' + existing + '; no login/launch requested')
        return
    page = work / 'download.html'
    fetch(PAGE, page)
    url, build = release(page.read_text(), arch)
    archive = work / 'Antigravity.tar.gz'
    headers = fetch(url, archive)
    verify_download(archive, headers)
    root, _, _ = locations(home)
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.stage-', dir=root) as tmp:
        app = unpack(archive, Path(tmp), arch)
        app_version(app, arch)
        check = subprocess.run(['ldd', str(app / 'antigravity')], capture_output=True, text=True, timeout=30)
        if check.returncode or 'not found' in check.stdout + check.stderr:
            raise ValueError('Desktop runtime libraries unavailable: ' + check.stdout + check.stderr)
        publish(app, home, build, arch)
    print('Verified Antigravity desktop ' + build + '; launcher antigravity.desktop. No login/launch requested.')
    print('Uses Electron sandbox as shipped; no --no-sandbox workaround or system policy changes.')


if __name__ == '__main__':
    try:
        install()
    except Exception as error:
        print('ERROR: Antigravity desktop blocked: ' + str(error), file=sys.stderr)
        sys.exit(1)
PY_ANTIGRAVITY
}

ai_main() {
    [[ $# == 1 ]] || { ai_error 'Usage: Install_AI_Tool_linux.sh claude-code|codex|antigravity'; return 1; }
    case "$1" in claude-code|codex|antigravity) ;; *) ai_error 'Unknown AI tool'; return 1 ;; esac
    [[ "$(uname -s)" == Linux && "$EUID" -ne 0 ]] || { ai_error 'Run on Ubuntu as the logged-in technician WITHOUT sudo'; return 1; }
    local account_home command
    account_home=$(getent passwd "$(id -u)" | cut -d: -f6)
    [[ "$HOME" == "$account_home" && -d "$HOME" && -O "$HOME" && -w "$HOME" ]] || { ai_error 'HOME must belong to the current technician'; return 1; }
    # Only this supported onboarding platform; never bootstrap dependencies as root.
    [[ -r /etc/os-release ]] || return 1
    . /etc/os-release
    [[ "$ID" == ubuntu && "${VERSION_ID%%.*}" -ge 22 ]] || { ai_error 'Ubuntu 22.04+ required'; return 1; }
    for command in curl timeout; do
        command -v "$command" >/dev/null || { ai_error "Missing prerequisite: $command"; return 1; }
    done
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/ai-install.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    case "$1" in
        claude-code) ai_install_native claude ;;
        codex) ai_install_native codex ;;
        antigravity)
            command -v python3 >/dev/null || { ai_error 'Missing prerequisite: python3'; return 1; }
            ai_install_antigravity ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    ai_main "$@"
fi
