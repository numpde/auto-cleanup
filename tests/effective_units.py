"""Effective manager state must match enrolled execution and calendar authority."""
import copy
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
controller = runpy.run_path(str(REPO / 'scripts/auto-cleanup'))
Installation = controller['Installation']
from systemd_state import dropin_names, manager_unit_paths, unit_properties

TARGET = json.loads((REPO / 'examples/agent-mail.json').read_text())
UNIT_DIR = '/etc/systemd/system'
SERVICE = 'auto-cleanup-docker@agent-mail.service'
TIMER = 'auto-cleanup-docker@agent-mail.timer'
ARGV = ['/usr/local/lib/auto-cleanup/docker-clean', '--config', '/etc/auto-cleanup/docker/agent-mail.json']
PROPERTIES = {
    SERVICE: {'Unit': {'FragmentPath': UNIT_DIR + '/auto-cleanup-docker@.service',
                      'DropInPaths': [UNIT_DIR + '/' + SERVICE + '.d/target.conf']},
              'Service': {'User': 'agent-mail', 'ExecStart': [[ARGV[0], ARGV, False, 0, 0, 0, 0, 0, 0, 0]]}},
    TIMER: {'Unit': {'FragmentPath': UNIT_DIR + '/auto-cleanup-docker@.timer',
                    'DropInPaths': [UNIT_DIR + '/' + TIMER + '.d/schedule.conf']},
            'Timer': {'TimersCalendar': [['OnCalendar', '*-*-* 00:00:00', 0]], 'TimersMonotonic': []}},
}
TYPES = {'User': 's', 'ExecStart': 'a(sasbttttuii)', 'FragmentPath': 's', 'DropInPaths': 'as',
         'TimersCalendar': 'a(sst)', 'TimersMonotonic': 'a(stt)'}


def bus(properties):
    def read(argv, env=None):
        assert argv[:3] == ['busctl', '--system', '--json=short']
        if argv[3] == 'call':
            return json.dumps(dict(type='o', data=['/org/freedesktop/systemd1/unit/' + argv[-1].replace('@', '_40').replace('-', '_2d').replace('.', '_2e')]))
        name = SERVICE if 'service' in argv[5] else TIMER
        interface = argv[6].rsplit('.', 1)[1]
        return '\n'.join(json.dumps(dict(type=TYPES[key],
                                        data=properties[name][interface][key])) for key in argv[7:])
    return read


with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as scratch:
    root = Path(scratch)
    args = SimpleNamespace(root=str(root), scope='docker', action='install', dry_run=False)
    installation = Installation(args)
    cases = [('service-user', SERVICE, 'Service', 'User', 'root'),
             ('service-argv', SERVICE, 'Service', 'ExecStart', [[ARGV[0], [ARGV[0]], False]]),
             ('service-ignore-failure', SERVICE, 'Service', 'ExecStart', [[ARGV[0], ARGV, True]]),
             ('service-invalid-ignore-flag', SERVICE, 'Service', 'ExecStart', [[ARGV[0], ARGV, 0]]),
             ('extra-command', SERVICE, 'Service', 'ExecStart', PROPERTIES[SERVICE]['Service']['ExecStart'] * 2),
             ('source', SERVICE, 'Unit', 'FragmentPath', '/run/systemd/transient/' + SERVICE),
             ('dropin', SERVICE, 'Unit', 'DropInPaths', ['/etc/systemd/system/service.d/override.conf']),
             ('calendar', TIMER, 'Timer', 'TimersCalendar', [['OnCalendar', '*-*-* 12:00:00', 0]]),
             ('extra-calendar', TIMER, 'Timer', 'TimersCalendar', PROPERTIES[TIMER]['Timer']['TimersCalendar'] * 2),
             ('monotonic', TIMER, 'Timer', 'TimersMonotonic', [['OnBootUSec', 1, 0]])]
    globals_ = Installation.verify_effective_units.__globals__
    with patch.dict(globals_, command=bus(PROPERTIES)):
        installation.verify_effective_units(TARGET)
    for name, unit, interface, key, value in cases:
        changed = copy.deepcopy(PROPERTIES)
        changed[unit][interface][key] = value
        try:
            with patch.dict(globals_, command=bus(changed)):
                installation.verify_effective_units(TARGET)
        except ValueError:
            pass
        else:
            raise AssertionError(f'accepted conflicting effective state: {name}')
    installation.unit_paths = [UNIT_DIR, '/run/systemd/transient', '/etc/systemd/system.control']
    for suffix in ('service', 'timer'):
        path = root / 'run/systemd/transient' / ('vps-docker-clean.' + suffix)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('[Unit]\n')
        try:
            installation.refuse_legacy_cleanup()
        except ValueError:
            pass
        else:
            raise AssertionError('alternate legacy unit bypassed enrollment guard')
        path.unlink()
    direct = root / 'run/systemd/transient' / SERVICE
    direct.write_text('[Service]\n')
    try:
        installation.verify_unit_sources(TARGET)
    except ValueError:
        pass
    else:
        raise AssertionError('alternate target unit bypassed source guard')
    direct.unlink()
    for inherited in ('service.d', 'timer.d', 'auto-cleanup-.service.d', 'auto-cleanup-docker@agent-.service.d'):
        directory = root / 'etc/systemd/system' / inherited
        directory.mkdir(parents=True)
        override = directory / 'override.conf'
        override.write_text('[Service]\nUser=root\n')
        try:
            installation.verify_unit_sources(TARGET)
        except ValueError:
            pass
        else:
            raise AssertionError(f'inherited drop-in bypassed preflight: {inherited}')
        override.unlink()

assert 'auto-cleanup-docker@.service' in dropin_names(SERVICE)

for reply in ('[]', '{"type":"o","data":[]}', '{"type":"o","data":["--unexpected"]}'):
    try:
        unit_properties(lambda argv: reply, SERVICE, 'Service', ('User',))
    except ValueError:
        pass
    else:
        raise AssertionError('malformed unit object accepted')
assert manager_unit_paths(lambda argv: '{"type":"as","data":["/etc/systemd/system"]}') == ['/etc/systemd/system']
print('effective systemd authority ok')
