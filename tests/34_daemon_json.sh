#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
python3 - "$REPO_DIR" <<'PY'
import json
import importlib.util
import types
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='auto-cleanup-json-', dir=os.environ['TMPDIR']) as scratch:
    root = Path(scratch)
    daemon = root / 'daemon.json'
    policy = root / 'policy.json'
    valid = json.loads((repo / 'fixtures/docker/daemon-log-policy.json').read_text())
    command = [str(repo / 'lib/merge-docker-daemon.py'), '--daemon-json', str(daemon), '--policy-json', str(policy)]
    original = '{"data-root":"/kept","debug":false}\n'
    daemon.write_text(original)
    daemon.chmod(0o600)
    metadata = daemon.stat()
    for key, value in [('data-root', '/overwritten'), ('debug', True)]:
        policy.write_text(json.dumps(dict(valid, **{key: value})))
        result = subprocess.run(command, text=True, capture_output=True)
        assert result.returncode != 0 and key in result.stderr, result.stderr
        assert daemon.read_text() == original and not list(root.glob('*.bak.*'))
    policy.write_text(json.dumps(valid))
    result = subprocess.run(command + ['--output-json', str(daemon)], text=True, capture_output=True)
    assert result.returncode != 0 and 'output path must differ' in result.stderr, result.stderr
    assert daemon.read_text() == original and not list(root.glob('*.bak.*'))
    assert daemon.stat().st_mode == metadata.st_mode
    output = root / 'preview.json'
    result = subprocess.run(command + ['--output-json', str(output)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    expected = dict(json.loads(original), **valid)
    assert json.loads(output.read_text()) == expected
    assert daemon.read_text() == original and not list(root.glob('*.bak.*'))
    assert daemon.stat().st_mode == metadata.st_mode
    assert (daemon.stat().st_uid, daemon.stat().st_gid) == (metadata.st_uid, metadata.st_gid)
    for token in ['NaN', 'Infinity', '-Infinity', '1e400']:
        malformed = '{"unrelated":' + token + '}\n'
        daemon.write_text(malformed)
        for mode in [[], ['--check'], ['--dry-run']]:
            result = subprocess.run(command + mode, text=True, capture_output=True)
            assert result.returncode != 0 and 'invalid JSON' in result.stderr, result.stderr
            assert daemon.read_text() == malformed and not list(root.glob('*.bak.*'))
    daemon.write_text('{"unrelated":1.25}\n')
    result = subprocess.run(command, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(daemon.read_text())['unrelated'] == 1.25
    spec = importlib.util.spec_from_file_location('daemon_merger', repo / 'lib/merge-docker-daemon.py')
    merger = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(merger)
    merger.time = types.SimpleNamespace(strftime=lambda *args: 'fixed', gmtime=lambda: ())
    unrelated = root / 'unrelated'
    dangling = daemon.with_name(daemon.name + '.auto-cleanup.bak.fixed')
    dangling.symlink_to(unrelated)
    backup = merger.backup_path(daemon)
    assert backup != dangling
    info = daemon.stat()
    merger.copy_backup(daemon, backup, (info.st_uid, info.st_gid))
    assert backup.is_file() and not backup.is_symlink() and not unrelated.exists()
    assert backup.read_bytes() == daemon.read_bytes() and backup.stat().st_mode == info.st_mode
    for occupied in (backup, dangling):
        try:
            merger.copy_backup(daemon, occupied, (info.st_uid, info.st_gid))
        except FileExistsError:
            pass
        else:
            raise AssertionError('occupied backup path was overwritten')
    assert not unrelated.exists()
print('daemon JSON boundaries ok')
PY
