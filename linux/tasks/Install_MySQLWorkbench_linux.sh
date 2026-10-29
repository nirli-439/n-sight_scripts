#!/bin/bash
# Oracle MySQL Workbench 26.10.0 signed generic ZIP; Ubuntu 22.04+, amd64/arm64.
# N-Sight task timeout 1800. EXIT: 0 OK | 1001 unsupported/conflict | 1002 error.
# Client only: no SQL server, GUI launch, user preferences, data or service changes.
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
trap 'echo "CRITICAL: MySQL Workbench installation failed (line $LINENO)"; exit 1002' ERR
warning() { echo "WARNING: $*"; exit 1001; }
[ "$(id -u)" -eq 0 ] || warning 'Root required'
[ "$(uname -s)" = Linux ] && [ -r /etc/os-release ] || warning 'Ubuntu 22.04+ required'
. /etc/os-release
[ "${ID:-}" = ubuntu ] && dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || warning 'Ubuntu 22.04+ required'
case "$(dpkg --print-architecture)" in
    amd64) arch=x86_64 ;;
    arm64) arch=aarch64 ;;
    *) warning 'Only Ubuntu amd64/arm64 supported' ;;
esac
version=26.10.0
key=BCA43417C3B485DD128EC6D4B7B3B788A8D3785C
base=/opt/mysql-workbench
target=$base/$version
wrapper=/usr/local/bin/mysql-workbench
desktop=/usr/share/applications/mysql-workbench.desktop
for package in mysql-workbench mysql-workbench-community; do
    if [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || :)" = 'install ok installed' ]; then
        warning "Existing $package package preserved; remove/migrate manually before using this installer"
    fi
done
[ ! -e /usr/bin/mysql-workbench ] && [ ! -L /usr/bin/mysql-workbench ] || warning 'Existing system Workbench preserved'
existing=$(command -v mysql-workbench || :)
[ -z "$existing" ] || [ "$existing" = "$wrapper" ] || warning "Existing Workbench at $existing preserved"
if [ ! -f "$target/.oracle-managed" ] || [ -L "$target/.oracle-managed" ]; then
    for path in "$base" "$wrapper" "$desktop"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || warning "Unmanaged Workbench path preserved: $path"
    done
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/mysql-workbench.XXXXXXXX")
stage=''
trap 'rm -rf "$work"; [ -z "$stage" ] || rm -rf "$stage"' EXIT
# Ubuntu repositories only. Block DB package changes, removals and upgrades,
# including dependency upgrades; never add Oracle APT sources or foreign DEBs.
cat > "$work/protect" <<'PINS'
Package: *mysql* *mariadb* *percona* *postgresql* *mongodb*
Pin: version *
Pin-Priority: -1
PINS
safe=(-o "Dir::Etc::preferences=$work/protect" --no-remove --no-upgrade --no-install-recommends)
install_prereqs() {
    [ "$#" -gt 0 ] || return 0
    apt-get -o APT::Update::Error-Mode=any update -qq
    apt-get "${safe[@]}" --simulate install "$@" > "$work/plan"
    while read -r action package rest; do
        case "$action" in
            Remv) warning "APT would remove $package; refusing" ;;
            Inst|Conf)
                case "$package" in *mysql*|*mariadb*|*percona*|*postgresql*|*mongodb*) warning "APT would change DB package $package; refusing" ;; esac
                if [ "$action" = Inst ] && [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || :)" = 'install ok installed' ]; then
                    warning "APT would upgrade existing package $package; refusing"
                fi ;;
        esac
    done < "$work/plan"
    apt-get "${safe[@]}" -y -qq install "$@"
}
missing=()
for item in curl:curl gpg:gnupg python3:python3; do
    command -v "${item%%:*}" >/dev/null || missing+=("${item#*:}")
done
[ -s /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
install_prereqs ${missing[@]+"${missing[@]}"}
# Reject symlink/writable installation ancestors before root writes beneath them.
python3 - "$base" "$target" "$wrapper" "$desktop" <<'PY'
import os, pathlib, stat, sys
for name in sys.argv[1:]:
    path = pathlib.Path(name)
    for parent in path.parents:
        if parent.exists() or parent.is_symlink():
            s = parent.lstat()
            if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or s.st_mode & 0o022:
                sys.exit(f'Unsafe installation ancestor: {parent}')
    if path.is_symlink():
        sys.exit(f'Refusing symlink: {path}')
PY
mkdir -m 0700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"
fetch() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS --retry 2 --connect-timeout 30 --max-time 900 --max-filesize 629145600 "$1" -o "$2"; }
fetch https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 "$work/key.asc"
fingerprint=$(gpg --batch --show-keys --with-colons "$work/key.asc" | awk -F: '$1 == "fpr" { print $10; exit }')
[ "$fingerprint" = "$key" ] || warning 'Unexpected Oracle signing key fingerprint'
gpg --batch --import "$work/key.asc" >/dev/null 2>&1
url="https://cdn.mysql.com/Downloads/MySQLGUITools/mysql-workbench-$version-linux-glibc2.28-$arch.zip"
fetch "$url" "$work/app.zip"
fetch "$url.asc" "$work/app.zip.asc"
gpg --batch --no-auto-key-retrieve --status-fd 1 --verify "$work/app.zip.asc" "$work/app.zip" > "$work/signature"
awk -v key="$key" '$2 == "VALIDSIG" && ($3 == key || $NF == key) {valid=1} END {exit !valid}' "$work/signature"
install -d -m 0755 "$base"
stage=$(mktemp -d "$base/.stage.XXXXXXXX")
# Real vendor layout is flat: mysql-workbench is ELF, resources/app/package.json
# is the product version; top-level 'version' is Electron's, not Workbench's.
python3 - "$work/app.zip" "$stage" "$arch" "$key" <<'PY'
import json, os, pathlib, shutil, stat, sys, zipfile
archive, dest, arch, key = sys.argv[1:]
dest = pathlib.Path(dest)
with zipfile.ZipFile(archive) as z:
    entries = z.infolist()
    if len(entries) > 20000 or sum(i.file_size for i in entries) > 3 * 1024**3:
        sys.exit('ZIP exceeds entry/expanded-size bounds')
    seen = set()
    for i in entries:
        p = pathlib.PurePosixPath(i.filename)
        mode = i.external_attr >> 16
        if (not i.filename or p.is_absolute() or '..' in p.parts or '\\' in i.filename
                or any(ord(c) < 32 for c in i.filename) or str(p) in seen
                or mode & 0o7000 or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)
                or i.file_size > 1024**3 or i.flag_bits & 1):
            sys.exit(f'Unsafe ZIP entry: {i.filename!r}')
        seen.add(str(p))
    for i in entries:
        out = dest / i.filename
        if i.is_dir():
            out.mkdir(parents=True, exist_ok=True)
        else:
            out.parent.mkdir(parents=True, exist_ok=True)
            with z.open(i) as src, out.open('xb') as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
            out.chmod(0o755 if (i.external_attr >> 16) & 0o111 else 0o644)
for relative in ['mysql-workbench', 'resources/app/shell/bin/mysqlsh']:
    app = dest / relative
    with app.open('rb') as f:
        header = f.read(20)
    if header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != {'aarch64': 183, 'x86_64': 62}[arch] or not os.access(app, os.X_OK):
        sys.exit(f'Expected native executable missing/wrong architecture: {relative}')
metadata = json.loads((dest / 'resources/app/package.json').read_text())
if metadata.get('name') != 'mysql-workbench' or metadata.get('version') != '26.10.0':
    sys.exit('Unexpected Workbench product/version')
(dest / '.oracle-managed').write_text('26.10.0 ' + key + '\n')
for directory, _, _ in os.walk(dest):
    pathlib.Path(directory).chmod(0o755)
PY
# Electron GTK runtime packages, including Ubuntu 24+ time64 renames.
deps=(libnss3 libgbm1 libxss1 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2)
for pair in libgtk-3-0:libgtk-3-0t64 libasound2:libasound2t64 libatk-bridge2.0-0:libatk-bridge2.0-0t64 libcups2:libcups2t64; do
    candidate=${pair%%:*}
    dpkg --compare-versions "$VERSION_ID" lt 24.04 || candidate=${pair#*:}
    deps+=("$candidate")
done
missing=()
for package in "${deps[@]}"; do
    [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || :)" = 'install ok installed' ] || missing+=("$package")
done
install_prereqs ${missing[@]+"${missing[@]}"}
# ldd only runs after signature and ELF validation, without starting the GUI.
for binary in "$stage/mysql-workbench" "$stage/resources/app/shell/bin/mysqlsh"; do
    ldd "$binary" > "$work/ldd"
    ! grep -q 'not found' "$work/ldd" || { cat "$work/ldd"; warning 'Missing runtime libraries; not installed'; }
done
python3 - "$stage" "$target" "$wrapper" "$desktop" <<'PY'
import filecmp, os, pathlib, stat, sys
stage, target, wrapper, desktop = map(pathlib.Path, sys.argv[1:])
wrapper_text = '#!/bin/sh\nexec "' + str(target / 'mysql-workbench') + '" "$@"\n'
desktop_text = '[Desktop Entry]\nType=Application\nName=MySQL Workbench\nExec=' + str(wrapper) + ' %U\nTerminal=false\nCategories=Development;Database;\n'
def inventory(root):
    result = {}
    for p in [root, *root.rglob('*')]:
        s = p.lstat()
        if s.st_uid != os.geteuid() or stat.S_ISLNK(s.st_mode) or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)) or s.st_mode & 0o7022:
            sys.exit(f'Unsafe managed installation: {p}')
        result[str(p.relative_to(root))] = (stat.S_IMODE(s.st_mode), p.is_dir())
    return result
if target.exists():
    if inventory(stage) != inventory(target):
        sys.exit('Existing managed target differs; preserved, migrate manually')
    for p in stage.rglob('*'):
        if p.is_file() and not filecmp.cmp(p, target / p.relative_to(stage), shallow=False):
            sys.exit('Existing managed content differs; preserved, migrate manually')
for p, text, mode in [(wrapper, wrapper_text, 0o755), (desktop, desktop_text, 0o644)]:
    if p.exists() or p.is_symlink():
        s = p.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) != mode or p.read_text() != text:
            sys.exit(f'Existing launcher differs; preserved: {p}')
if not target.exists():
    stage.rename(target)
for p, text, mode in [(wrapper, wrapper_text, 0o755), (desktop, desktop_text, 0o644)]:
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    if not p.exists():
        with p.open('x') as f:
            f.write(text)
        p.chmod(mode)
print('OK: Oracle MySQL Workbench 26.10.0 installed and verified (signature, native ELF, product version, runtime libraries); not launched.')
PY
exit 0
