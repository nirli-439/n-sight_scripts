#!/usr/bin/env python3
"""Ubuntu account-only offboarding. Always preserve homes and system/current users.
Run: sudo python3 Offboard_Users_linux.py --keep "$USER" [--list]
No unattended deletion mode: exact selection and typed confirmation require /dev/tty.
"""
import argparse
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import subprocess
import sys

PASSWD = Path('/etc/passwd')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]*\$?\Z')


def read_accounts(path=PASSWD):
    accounts = {}
    for line in path.read_text().splitlines():
        fields = line.split(':')
        if len(fields) != 7 or not fields[2].isdigit() or not fields[3].isdigit():
            raise ValueError('Invalid local passwd database; no users removed')
        name, _, uid, gid, comment, home, shell = fields
        if name in accounts:
            raise ValueError('Duplicate local account names; no users removed')
        accounts[name] = dict(name=name, uid=int(uid), gid=int(gid), comment=comment,
                              home=home, shell=shell)
    return accounts


def uid_limits(path=Path('/etc/login.defs')):
    values = {'UID_MIN': 1000, 'UID_MAX': 60000, 'SYS_UID_MAX': 999}
    for line in path.read_text().splitlines():
        fields = line.split('#', 1)[0].split()
        if len(fields) == 2 and fields[0] in values:
            values[fields[0]] = int(fields[1])
    minimum = max(values['UID_MIN'], values['SYS_UID_MAX'] + 1)
    if not 1000 <= minimum <= values['UID_MAX'] < 65534:
        raise ValueError('Unusual UID range; review accounts manually')
    return minimum, values['UID_MAX']


def candidates(accounts, protected_names, protected_uids, minimum, maximum):
    return sorted((a for a in accounts.values()
                   if minimum <= a['uid'] <= maximum
                   and a['name'] not in protected_names and a['uid'] not in protected_uids
                   and NAME.fullmatch(a['name'])
                   and a['shell'].startswith('/')
                   and Path(a['shell']).name not in ('nologin', 'false', 'sync', 'shutdown', 'halt')),
                  key=lambda a: a['name'])


def choose(text, accounts):
    fields = text.split()
    if not fields:
        return []
    if any(not field.isdecimal() or not 1 <= int(field) <= len(accounts) for field in fields):
        raise ValueError('Select only the listed account numbers, separated by spaces')
    return [accounts[i] for i in sorted({int(field)-1 for field in fields})]


def has_processes(uid):
    result = subprocess.run(['pgrep', '-u', str(uid)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, text=True)
    if result.returncode not in (0, 1):
        raise ValueError('Cannot verify active processes; no removal allowed')
    return result.returncode == 0


def preflight(account, path, running, protected_names, protected_uids):
    if account['name'] in protected_names or account['uid'] in protected_uids:
        raise ValueError('Protected technician account cannot be removed')
    current = read_accounts(path).get(account['name'])
    if current != account:
        raise ValueError('Account changed since preview; restart the selection')
    if running(account['uid']):
        raise ValueError('Account has active processes; log it out and stop its jobs first')


def remove_account(account, path, run, running, *, protected_names, protected_uids):
    preflight(account, path, running, protected_names, protected_uids)
    home = Path(account['home'])
    home_existed = home.exists() or home.is_symlink()
    # Deliberately no -r, --remove, --force or recursive filesystem deletion.
    result = run(['userdel', '--', account['name']], check=False)
    if result.returncode or account['name'] in read_accounts(path):
        raise ValueError('Account removal failed or verification failed: ' + account['name'])
    if home_existed and not (home.exists() or home.is_symlink()):
        raise ValueError('Home unexpectedly missing; stop and investigate: ' + str(home))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keep', required=True, help='Technician account that must never be removed')
    parser.add_argument('--list', action='store_true', help='Read-only candidate preview; never delete')
    args = parser.parse_args(argv)
    if os.geteuid() != 0 or platform.system() != 'Linux':
        raise ValueError('Run on Ubuntu as root with an explicit --keep technician')
    release = platform.freedesktop_os_release()
    if release.get('ID') != 'ubuntu' or int(release['VERSION_ID'].split('.')[0]) < 22:
        raise ValueError('Ubuntu 22.04+ required')
    os.umask(0o022)  # Native account tools maintain system database file modes.
    if not shutil.which('pgrep') or not shutil.which('userdel'):
        raise ValueError('pgrep and userdel are required; no users removed')
    keep = pwd.getpwnam(args.keep)
    if keep.pw_uid == 0:
        raise ValueError('--keep must identify the nonroot technician, not root')
    protected_names, protected_uids = {args.keep, 'root', 'nobody'}, {0, 65534, keep.pw_uid}
    if os.environ.get('SUDO_USER'):
        sudo_user = pwd.getpwnam(os.environ['SUDO_USER'])
        protected_names.add(sudo_user.pw_name)
        protected_uids.add(sudo_user.pw_uid)
    minimum, maximum = uid_limits()
    eligible = candidates(read_accounts(), protected_names, protected_uids, minimum, maximum)
    # Refuse active users, including graphical sessions and background user jobs.
    inactive = []
    for account in eligible:
        if has_processes(account['uid']):
            print('Protected while active: ' + account['name'])
        else:
            inactive.append(account)
    print('Account-only cleanup. Home folders/data are KEPT. This is NOT a factory reset.')
    print('Always kept: system/service accounts, active users, ' + args.keep)
    for i, account in enumerate(inactive, 1):
        print(f"{i}. {account['name']} (UID {account['uid']}) - keep home {account['home']}")
    if args.list or not inactive:
        print('Preview only; no accounts removed.' if args.list else 'No eligible inactive local users.')
        return 0
    with open('/dev/tty', 'r') as tty_input, open('/dev/tty', 'w') as tty:
        tty.write('Select account numbers separated by spaces (empty = cancel): ')
        tty.flush()
        selected = choose(tty_input.readline(), inactive)
        if not selected:
            print('Cancelled; no accounts removed.')
            return 1001
        for account in selected:
            preflight(account, PASSWD, has_processes, protected_names, protected_uids)
        phrase = 'REMOVE ' + ' '.join(a['name'] for a in selected)
        tty.write('Homes stay in place; original ownership is preserved. Retain encryption recovery keys first.\n')
        tty.write('Remove exactly: ' + ', '.join(a['name'] for a in selected) + '\n')
        tty.write('Type exactly "' + phrase + '" to confirm: ')
        tty.flush()
        if tty_input.readline().rstrip('\r\n') != phrase:
            print('Cancelled; confirmation did not match. No accounts removed.')
            return 1001
        for account in selected:
            remove_account(account, PASSWD, subprocess.run, has_processes,
                           protected_names=protected_names, protected_uids=protected_uids)
            print('Verified removed account: ' + account['name'] + '; home/data preserved.')
    print('Offboarding complete. Home folders remain; do not reuse their UIDs without reviewing access.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as error:
        print('CRITICAL: ' + str(error), file=sys.stderr)
        sys.exit(1002)
