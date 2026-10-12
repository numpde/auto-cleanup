"""Exercise immutable protection, fail-closed inputs and retention effects."""
import copy
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
CURRENT = 'sha256:' + 'a' * 64
OLD = 'sha256:' + 'b' * 64
YOUNG = 'sha256:' + 'c' * 64
DIGEST = 'example.test/app@sha256:' + 'd' * 64
STATE = {'images': [
    {'Id': CURRENT, 'RepoDigests': [DIGEST], 'Created': '2020-01-01T00:00:00Z'},
    {'Id': OLD, 'Created': '2020-01-01T00:00:00Z'},
    {'Id': YOUNG, 'Created': dt.datetime.now(dt.timezone.utc).isoformat()},
], 'containers': {}}
INVENTORY = {'version': 1, 'daemon_id': 'test-daemon', 'expires_at': '2099-01-01T00:00:00Z',
             'deployments': {'app': {'current': [DIGEST], 'rollback': []}}, 'recovery': []}


def exercise(inventory=INVENTORY, state=STATE, budget='0', locked=False, inventory_mode=0o600, lock_mode=0o600):
    with tempfile.TemporaryDirectory(prefix='auto-cleanup-retention-', dir=os.environ['TMPDIR']) as scratch:
        root = Path(scratch)
        path = root / 'protection.json'
        if inventory is not None:
            path.write_text(inventory if isinstance(inventory, str) else json.dumps(inventory))
            path.chmod(inventory_mode)
        state_path = root / 'state.json'
        state_path.write_text(json.dumps(state))
        env = dict(os.environ, DOCKER=str(REPO / 'tests/fixtures/fake-retention-docker.py'),
                   IMAGE_PROTECTION_FILE=str(path), RETENTION_STATE=str(state_path),
                   FAKE_DOCKER_LOG=str(root / 'log'), IMAGE_MIN_FREE_GIB=budget,
                   CONTAINER_UNTIL='24h', NETWORK_UNTIL='24h', IMAGE_UNTIL='24h')
        with Path(str(path) + '.lock').open('w') as lock:
            os.fchmod(lock.fileno(), lock_mode)
            if locked:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean')], env=env,
                                    text=True, capture_output=True, timeout=15)
        log = (root / 'log').read_text()
        remaining = {image['Id'] for image in json.loads(state_path.read_text())['images']}
        assert 'image prune' not in log and 'volume' not in log and 'buildx' not in log
        return result, log, remaining


result, log, remaining = exercise()
assert result.returncode == 0, result.stderr
assert remaining == {CURRENT, YOUNG}, remaining
assert f'image rm --no-prune {OLD}' in log

# Every container reference protects an image even when disposable pruning runs.
state = copy.deepcopy(STATE)
state['containers'] = {'stopped': OLD}
state['disposable_containers'] = True
result, log, remaining = exercise(state=state)
assert result.returncode == 0 and remaining == {CURRENT, OLD, YOUNG}, result.stderr

for role in ('rollback', 'recovery'):
    state = copy.deepcopy(STATE)
    rollback = 'example.test/rollback@sha256:' + 'e' * 64
    state['images'][1]['RepoDigests'] = [rollback]
    inventory = copy.deepcopy(INVENTORY)
    if role == 'rollback':
        inventory['deployments']['app']['rollback'] = [rollback]
    else:
        inventory['recovery'] = [rollback]
    result, log, remaining = exercise(inventory, state)
    assert result.returncode == 0 and OLD in remaining, result.stderr

invalid = [None, '{}', '{"version":1,"version":1}']
for key, value in [('expires_at', '2000-01-01T00:00:00Z'), ('expires_at', None),
                   ('daemon_id', 'other-daemon'), ('deployments', {})]:
    inventory = copy.deepcopy(INVENTORY)
    inventory[key] = value
    invalid.append(inventory)
inventory = copy.deepcopy(INVENTORY)
inventory['deployments']['app']['current'] = ['example.test/app:latest']
invalid.append(inventory)
for inventory in invalid:
    result, log, remaining = exercise(inventory)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log, (result.stderr, log)
    assert 'Traceback' not in result.stderr, result.stderr

state = copy.deepcopy(STATE)
state['images'] = state['images'][1:]
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and 'prune' not in log
state = copy.deepcopy(STATE)
state['containers'] = {'broken-running-gui': 'sha256:' + 'f' * 64}
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and 'prune' not in log
result, log, remaining = exercise(locked=True)
assert result.returncode != 0 and 'prune' not in log

for modes in ({'inventory_mode': 0o666}, {'lock_mode': 0o666}):
    result, log, remaining = exercise(**modes)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log

state = copy.deepcopy(STATE)
state['malformed_inspect'] = True
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and 'prune' not in log and 'Traceback' not in result.stderr
assert 'cannot resolve one image object' in result.stderr

state = copy.deepcopy(STATE)
state['change_inventory'] = True
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and 'network prune' not in log and 'image rm' not in log

state = copy.deepcopy(STATE)
state['refuse_removal'] = True
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and OLD in remaining

# Pressure can evict younger unprotected images, never protected images, and
# reports an unmet floor rather than claiming shared layers released bytes.
result, log, remaining = exercise(budget='999999')
assert result.returncode != 0 and remaining == {CURRENT}, (result.stderr, remaining)
assert 'Cannot meet' in result.stderr
print('image retention ok')
