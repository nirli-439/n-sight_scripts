#!/usr/bin/env python3
"""Sandboxed Slack installer regression; never installs apps or mounts images."""
from pathlib import Path
import os
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'tasks/Install_Slack_mac.sh'
source = script.read_text()
subprocess.run(['/bin/bash', '-n', str(script)], check=True)
stubs = r'''
log_event() { printf '%s\n' "$*" >> "$EVENTS"; }
curl() { log_event download; [[ "$CASE" != download_fail ]]; }
hdiutil() {
    log_event "hdiutil $*"
    if [[ "$1" == attach ]]; then
        [[ "$CASE" != mount_fail ]] || return 1
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -mountpoint ]]; then shift; mount="$1"; fi
            shift
        done
        [[ "$CASE" == missing_source ]] || mkdir -p "$mount/Slack.app/Contents"
    fi
}
defaults() {
    if [[ "$2" == "$APPS/Slack.app/Contents/Info" && "$CASE" == invalid_existing ]]; then
        echo org.unrelated.app
    elif [[ "$3" == CFBundleIdentifier ]]; then
        [[ "$CASE" == bad_bundle ]] && echo org.unrelated.app || echo com.tinyspeck.slackmacgap
    else echo test; fi
}
codesign() {
    log_event "codesign $*"
    local requirement="" previous="" arg
    for arg in "$@"; do
        [[ "$previous" != -R ]] || requirement="$arg"
        previous="$arg"
    done
    /usr/bin/csreq -r "$requirement" -t >/dev/null 2>&1 || return 1
    [[ "$CASE" != bad_signature && "$CASE" != bad_team ]]
}
spctl() { log_event "spctl $*"; [[ "$CASE" != rejected ]]; }
stat() { echo "${CONSOLE_USER:-loginwindow}"; }
id() { [[ "$*" == '-u alice' ]] && echo 501; }
chown() { log_event "chown $*"; }
cp() { log_event "copy $*"; /bin/cp "$@"; }
rm() {
    local arg
    for arg in "$@"; do
        case "$arg" in -*) ;; "$TMPDIR"/*) ;; *) log_event "blocked rm $*"; return 1 ;; esac
    done
    /bin/rm "$@"
}
xattr() { log_event FORBIDDEN_XATTR; return 1; }
sw_vers() { echo test; }
'''
# Replace only the fixed install path and privilege check in the in-memory copy.
# All system-mutating commands are stubbed above; cp/rm only reach this sandbox.
for case in ('invalid_existing', 'existing', 'fresh', 'download_fail', 'mount_fail',
             'missing_source', 'bad_bundle', 'bad_signature', 'bad_team', 'rejected', 'user'):
    with tempfile.TemporaryDirectory(prefix='slack-regression-') as temp:
        root = Path(temp)
        apps = root / 'Applications'
        apps.mkdir()
        events = root / 'events'
        events.touch()
        if case in ('invalid_existing', 'existing'):
            (apps / 'Slack.app').mkdir()
            (apps / 'Slack.app/sentinel').write_text('preserve')
        code = source.replace('/Applications', str(apps))
        code = code.replace('[[ $EUID -eq 0 ]] || fail "Root privileges required"', ':')
        assert '# --- Root check ---' in code
        code = code.replace('# --- Root check ---', stubs + '\n# --- Root check ---')
        env = dict(os.environ, CASE=case, EVENTS=str(events), APPS=str(apps),
                   TMPDIR=temp, CONSOLE_USER='alice' if case == 'user' else 'loginwindow')
        result = subprocess.run(['/bin/bash'], input=code, text=True,
                                capture_output=True, env=env)
        lines = events.read_text().splitlines()
        success = case in ('fresh', 'user', 'existing')
        assert result.returncode == (0 if success else 234), (case, result.stdout, result.stderr)
        copied = any(line.startswith('copy ') for line in lines)
        assert copied == (case in ('fresh', 'user')), (case, lines)
        detaches = [line for line in lines if line.startswith('hdiutil detach ')]
        attached = case not in ('existing', 'invalid_existing', 'download_fail', 'mount_fail')
        assert len(detaches) == int(attached), (case, lines)
        assert all(temp in line for line in detaches), (case, lines)
        assert 'FORBIDDEN_XATTR' not in lines
        if case in ('invalid_existing', 'existing'):
            assert (apps / 'Slack.app/sentinel').read_text() == 'preserve'
            assert 'download' not in lines
        if copied:
            index = next(i for i, line in enumerate(lines) if line.startswith('copy '))
            assert any(line.startswith('spctl ') for line in lines[:index]), lines
            assert any('BQR82RBBHL' in line and 'anchor apple generic' in line
                       and 'com.tinyspeck.slackmacgap' in line for line in lines[:index]), lines
            expected = 'alice:staff' if case == 'user' else 'root:wheel'
            assert any(expected in line for line in lines if line.startswith('chown ')), lines
        assert not list(root.glob('slack-install.*')), (case, 'work directory leaked')
code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('#'))
for forbidden in ('com.apple.dock', 'persistent-apps', 'killall Dock', 'xattr ', 'find /Volumes', 'rm -rf "$APP_PATH"'):
    assert forbidden not in code, forbidden
print('PASS: Bash syntax and 11 sandboxed install/security/cleanup/ownership cases; no Dock or quarantine changes')
