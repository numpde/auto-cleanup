"""Migration refuses changed authority and hands scheduling over in order."""
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
Installation = runpy.run_path(str(REPO / 'scripts/auto-cleanup'))['Installation']


def legacy(root):
    files = {
        '/usr/local/sbin/vps-docker-clean': (REPO / 'fixtures/legacy/vps-docker-clean').read_bytes(),
        '/etc/systemd/system/vps-docker-clean.service': (REPO / 'fixtures/legacy/vps-docker-clean.service').read_text().replace('@SBIN_DIR@', '/usr/local/sbin').replace('@ETC_DIR@', '/etc').encode(),
        '/etc/systemd/system/vps-docker-clean.timer': (REPO / 'fixtures/legacy/vps-docker-clean.timer').read_text().replace('@SCHEDULE@', 'daily').encode(),
        '/etc/default/vps-docker-clean.policy': b'PROFILE=vps\nCACHE_GIB=1\nSCHEDULE=daily\nCONTAINER_UNTIL=24h\nNETWORK_UNTIL=24h\nIMAGE_UNTIL=24h\n',
        '/etc/default/vps-docker-clean': b'IMAGE_UNTIL=168h\nIMAGE_MIN_FREE_GIB=5\n',
        '/etc/default/vps-docker-clean.images.json': b'{"retained":"inventory"}\n',
        '/etc/default/vps-docker-clean.images.json.lock': b'stable lock\n',
        '/etc/docker/daemon.json': b'{"unrelated":true}\n',
        '/etc/systemd/journald.conf.d/auto-cleanup-limits.conf': b'host policy\n',
    }
    for destination, data in files.items():
        path = root / destination.lstrip('/')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.parent.chmod(0o755)
        path.write_bytes(data)
    return files


def config(path):
    target = dict(name='rootful', kind='rootful', user='root', socket='/var/run/docker.sock',
                  daemon_config=None, daemon_service=None, cache_gib=None, schedule='daily',
                  container_until='24h', network_until='24h', image_until='168h', image_min_free_gib=5,
                  image_protection_mode='inventory', image_keep_tags=[],
                  image_protection_file='/etc/default/vps-docker-clean.images.json')
    path.write_text(json.dumps(target))
    return target


with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as scratch:
    scratch = Path(scratch)
    proposed = scratch / 'reviewed.json'
    expected = config(proposed)
    successful = ('success', 'literal-quotes', 'disabled', 'dry-run')
    for case in (*successful, 'age', 'lockpath', 'unknown', 'quoted', 'duplicate', 'custom-executor',
                 'dropin', 'transient', 'control', 'stop-failure', 'disable-failure'):
        root = scratch / case
        original = legacy(root)
        changed = dict(expected)
        if case == 'literal-quotes':
            override = root / 'etc/default/vps-docker-clean'
            override.write_text("IMAGE_UNTIL='168h'\nIMAGE_MIN_FREE_GIB=5\n")
            original['/etc/default/vps-docker-clean'] = override.read_bytes()
        if case == 'age':
            changed['image_until'] = '24h'
        elif case == 'lockpath':
            changed['image_protection_file'] = '/var/lib/auto-cleanup/rootful/images.json'
        elif case in ('unknown', 'quoted', 'duplicate'):
            override = root / 'etc/default/vps-docker-clean'
            extra = {'unknown': 'UNKNOWN_SETTING=secret\n', 'quoted': 'IMAGE_PROTECTION_FILE="$(unsafe)"\n',
                     'duplicate': 'IMAGE_UNTIL=24h\n'}[case]
            override.write_text(override.read_text() + extra)
            original['/etc/default/vps-docker-clean'] = override.read_bytes()
        elif case == 'custom-executor':
            executable = root / 'usr/local/sbin/vps-docker-clean'
            executable.write_bytes(executable.read_bytes() + b'# custom\n')
            original['/usr/local/sbin/vps-docker-clean'] = executable.read_bytes()
        elif case in ('dropin', 'transient', 'control'):
            destination = {'dropin': 'etc/systemd/system/vps-docker-clean.service.d/change.conf',
                           'transient': 'run/systemd/transient/vps-docker-clean.service',
                           'control': 'etc/systemd/system.control/vps-docker-clean.service.d/change.conf'}[case]
            path = root / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('[Service]\nEnvironment=IMAGE_UNTIL=999h\n')
        proposed.write_text(json.dumps(changed))
        args = SimpleNamespace(root=str(root), scope='docker', action='migrate', name=None,
                               config=str(proposed), dry_run=case == 'dry-run', enable_timer=case != 'disabled', restart_docker=False, live=False)
        installation = Installation(args)
        events = []
        actual_write = Installation.write

        def service(*argv):
            events.append(('systemctl', *argv))
            if ((case == 'stop-failure' and argv == ('stop', 'vps-docker-clean.service')) or
                    (case == 'disable-failure' and argv == ('disable', '--now', 'vps-docker-clean.timer'))):
                raise RuntimeError('injected service failure')

        def write(self, destination, *args, **kwargs):
            events.append(('write', destination))
            return actual_write(self, destination, *args, **kwargs)

        installation.systemctl = service
        lock = root / 'etc/default/vps-docker-clean.images.json.lock'
        inode = lock.stat().st_ino
        try:
            with patch.object(Installation, 'write', write):
                installation.migrate_target()
        except (ValueError, RuntimeError):
            assert case not in successful, case
            assert not (root / 'etc/auto-cleanup').exists(), (case, events)
            for destination, data in original.items():
                assert (root / destination.lstrip('/')).read_bytes() == data, (case, destination)
            assert not any(event[0] == 'write' for event in events), (case, events)
            if case not in ('stop-failure', 'disable-failure'):
                assert not events, (case, events)
        else:
            assert case in successful, case
            assert events[:2] == [('systemctl', 'disable', '--now', 'vps-docker-clean.timer'),
                                  ('systemctl', 'stop', 'vps-docker-clean.service')], events
            if case == 'disabled':
                assert not any(event[:2] == ('systemctl', 'enable') for event in events)
            else:
                assert events[-1] == ('systemctl', 'enable', '--now', 'auto-cleanup-docker@rootful.timer')
            for destination in ('/etc/default/vps-docker-clean', '/etc/default/vps-docker-clean.images.json',
                                '/etc/default/vps-docker-clean.images.json.lock', '/etc/docker/daemon.json',
                                '/etc/systemd/journald.conf.d/auto-cleanup-limits.conf'):
                assert (root / destination.lstrip('/')).read_bytes() == original[destination]
            assert lock.stat().st_ino == inode
            if case == 'dry-run':
                for destination, data in original.items():
                    assert (root / destination.lstrip('/')).read_bytes() == data
                assert not (root / 'etc/auto-cleanup').exists()
            else:
                assert not (root / 'usr/local/sbin/vps-docker-clean').exists()
                assert (root / 'etc/auto-cleanup/docker/rootful.json').exists()
print('legacy migration ok')
