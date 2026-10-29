#!/usr/bin/env python3
"""Safe fixtures: no real account deletion or system account changes."""
import importlib.util
from pathlib import Path
import tempfile
import sys
sys.dont_write_bytecode=True

script=Path(__file__).with_name('Offboard_Users_linux.py')
assert script.exists(), 'Offboarding tool missing'
spec=importlib.util.spec_from_file_location('offboard',script)
assert spec is not None and spec.loader is not None
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='offboard-test-') as temp:
    root=Path(temp)
    passwd=root/'passwd'
    passwd.write_text('root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\ntechnician:x:1000:1000:Tech:/home/technician:/bin/bash\nalice:x:1001:1001:Alice:/home/alice:/bin/bash\nsvc:x:1100:1100:service:/srv/svc:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/:/usr/sbin/nologin\n')
    home=root/'home-alice';home.mkdir()
    passwd.write_text(passwd.read_text().replace('/home/alice',str(home)))
    accounts=module.read_accounts(passwd)
    assert [a['name'] for a in module.candidates(accounts,{'technician'},{1000},1000,60000)]==['alice']
    assert module.choose('1',[accounts['alice']])==[accounts['alice']]
    for bad in ('0','2','1; id','alice','1 -1'):
        try:module.choose(bad,[accounts['alice']]);raise AssertionError('invalid selection accepted')
        except ValueError:pass
    calls=[]
    def run(command,**kwargs):
        calls.append(command)
        class Result:returncode=0
        # Simulate userdel changing only the account database, not home contents.
        passwd.write_text('\n'.join(l for l in passwd.read_text().splitlines() if not l.startswith('alice:'))+'\n')
        return Result()
    sentinel=home/'keep-this-file';sentinel.write_text('preserve home')
    before=sentinel.stat().st_mtime_ns
    module.remove_account(accounts['alice'],passwd,run,lambda uid:False, protected_names={'technician'},protected_uids={1000})
    assert calls==[['userdel','--','alice']],calls
    assert sentinel.read_text()=='preserve home' and sentinel.stat().st_mtime_ns==before
    assert 'alice' not in module.read_accounts(passwd)
    try:module.remove_account(accounts['technician'],passwd,run,lambda uid:False, protected_names={'technician'},protected_uids={1000});raise AssertionError('protected account deletion allowed')
    except ValueError:pass
    assert len(calls)==1
    busy=dict(accounts['alice'],name='busy',uid=1002,home='/home/busy')
    passwd.write_text(passwd.read_text()+'busy:x:1002:1002:Busy:/home/busy:/bin/bash\n')
    try:module.remove_account(busy,passwd,run,lambda uid:True,protected_names={'technician'},protected_uids={1000});raise AssertionError('running user removal allowed')
    except ValueError:pass
    assert len(calls)==1
    passwd.write_text(passwd.read_text().replace('busy:x:1002:', 'busy:x:2002:'))
    try:module.remove_account(busy,passwd,run,lambda uid:False,protected_names={'technician'},protected_uids={1000});raise AssertionError('changed identity removed')
    except ValueError:pass
    assert len(calls)==1
    limits=root/'login.defs';limits.write_text('UID_MIN 1000\nUID_MAX 60000\nSYS_UID_MAX 999\n')
    assert module.uid_limits(limits)==(1000,60000)
# Exercise the exact production TTY open expressions on a real pseudo-terminal.
# No main() call, root privileges or userdel execution is involved.
import ast
import copy
import os
import pty
import signal
previous_hup=signal.signal(signal.SIGHUP,signal.SIG_IGN)
master,slave=pty.openpty()
try:
    tree=ast.parse(script.read_text())
    node=next(n for n in ast.walk(tree) if isinstance(n,ast.With) and any(
        isinstance(item.context_expr,ast.Call) and item.context_expr.args
        and isinstance(item.context_expr.args[0],ast.Constant)
        and item.context_expr.args[0].value=='/dev/tty' for item in n.items))
    node=copy.deepcopy(node)
    for item in node.items:
        assert isinstance(item.context_expr,ast.Call)
        item.context_expr.args[0]=ast.Constant(os.ttyname(slave))
    node.body=ast.parse('assert tty_input.readable() and tty.writable()').body
    exec(compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),'tty-check','exec'),{})
finally:
    os.close(master);os.close(slave)
    signal.signal(signal.SIGHUP,previous_hup)
print('PASS: protected/active users, exact selection, account-only removal, preserved homes and real non-seekable TTY streams')
