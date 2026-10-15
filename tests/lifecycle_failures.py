"""Lifecycle failures retain restart evidence and report potentially stopped timers."""
import contextlib
import io
import os
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
Installation = runpy.run_path(str(REPO / 'scripts/auto-cleanup'))['Installation']

with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as scratch:
    installation = Installation(SimpleNamespace(root=scratch, scope='docker', action='install', dry_run=False))
    target = {'name': 'selected', 'daemon_config': '/etc/docker/daemon.json'}
    result = 'backed up /etc/docker/daemon.json to /etc/docker/daemon.json.bak\nupdated /etc/docker/daemon.json'
    for failure in ('none', 'restore', 'recovery'):
        events = []
        original = RuntimeError('initial restart failed')

        def restart(target):
            events.append('restart')
            if events.count('restart') == 1:
                raise original
            if failure == 'recovery':
                raise RuntimeError('recovery restart failed')

        def restore(target, argv):
            assert argv == ['cp', '--preserve=mode,ownership,timestamps',
                            '/etc/docker/daemon.json.bak', '/etc/docker/daemon.json']
            events.append('restore')
            if failure == 'restore':
                raise OSError('backup restore failed')

        installation.restart_daemon = restart
        installation.owner_command = restore
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr):
                installation.restart_with_recovery(target, result)
        except RuntimeError as error:
            diagnostic = stderr.getvalue() + str(error)
            assert 'initial restart failed' in diagnostic
            if failure == 'restore':
                assert events == ['restart', 'restore']
                assert 'backup restore failed' in diagnostic and 'configuration restored' not in diagnostic
            else:
                assert events == ['restart', 'restore', 'restart']
                assert 'previous configuration restored' in diagnostic
                if failure == 'recovery':
                    assert 'recovery restart failed' in diagnostic
                else:
                    assert error is original
        else:
            raise AssertionError('restart failure was hidden')

    installation.registered = lambda: iter([{'name': 'first'}, {'name': 'second'}])
    for failure in ('first-pause', 'pause', 'write', 'resume'):
        events = []

        def pause(target):
            events.append(('pause', target['name']))
            if failure == 'first-pause' or (failure == 'pause' and target['name'] == 'second'):
                raise RuntimeError('cannot finish pausing target')
            return True

        def service(*argv):
            events.append(argv)
            if failure == 'resume':
                raise RuntimeError('cannot resume first')

        installation.pause_target = pause
        installation.systemctl = service
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr), installation.pause_runtime_users(target):
                if failure == 'write':
                    raise OSError('runtime write failed')
        except (OSError, RuntimeError):
            assert 'cleanup timers may remain stopped' in stderr.getvalue()
            expected = [('pause', 'first')] if failure == 'first-pause' else [('pause', 'first'), ('pause', 'second')]
            assert events[:len(expected)] == expected
            if failure != 'resume':
                assert not any(event[0] == 'start' for event in events)
        else:
            raise AssertionError('shared runtime failure was hidden')
print('lifecycle failure reporting ok')
