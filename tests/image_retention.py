"""Exercise chosen image protection, rejected inputs and retention effects."""
import copy
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import runpy
import pwd
import sys
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
CURRENT = 'sha256:' + 'a' * 64
OLD = 'sha256:' + 'b' * 64
YOUNG = 'sha256:' + 'c' * 64
DIGEST = 'example.test/app@sha256:' + 'd' * 64
TAG = 'example.test/app:latest'
STATE = {'images': [
    {'Id': CURRENT, 'RepoDigests': [DIGEST], 'RepoTags': [TAG], 'Created': '2020-01-01T00:00:00.123456789Z'},
    {'Id': OLD, 'Created': '2020-01-01T00:00:00.12345678Z'},
    {'Id': YOUNG, 'Created': dt.datetime.now(dt.timezone.utc).isoformat()},
], 'containers': {}, 'security_options': ['name=rootless']}
INVENTORY = {'version': 1, 'daemon_id': 'test-daemon', 'expires_at': '2099-01-01T00:00:00.123456789+03:00',
             'deployments': {'app': {'current': [DIGEST], 'rollback': []}}, 'recovery': []}


timestamp = runpy.run_path(str(REPO / 'fixtures/bin/vps-docker-clean'))['timestamp']
for zone, offset in [('Z', 0), ('+03:00', 180), ('-05:30', -330)]:
    expected_zone = dt.timezone(dt.timedelta(minutes=offset))
    assert timestamp('2020-02-29T12:34:56' + zone) == dt.datetime(2020, 2, 29, 12, 34, 56, tzinfo=expected_zone)
    for digits in range(1, 10):
        fraction = '123456789'[:digits]
        expected = dt.datetime(2020, 2, 29, 12, 34, 56,
                               int(fraction[:6].ljust(6, '0')), tzinfo=expected_zone)
        parsed = timestamp('2020-02-29T12:34:56.' + fraction + zone)
        assert parsed == expected and parsed.utcoffset() == expected.utcoffset(), parsed

malformed_timestamps = [
    '2099-01-01T00:00:00', '2099-01-01', '2099-02-29T00:00:00Z',
    '2099-13-01T00:00:00Z', '2099-01-01T24:00:00Z', '2099-01-01T00:60:00Z',
    '2099-01-01T00:00:60Z', '2099-01-01T00:00:00.Z',
    '2099-01-01T00:00:00.1234567890Z', '2099-01-01T00:00:00+24:00',
    '2099-01-01T00:00:00+03:60', '2099-01-01T00:00:00-03:60',
    '2099-01-01T00:00:00+0300', '2099-01-01T00:00:00+03:00:01',
    '2099-01-01 00:00:00Z', '2099-01-01T00:00:00Zjunk',
]
for value in malformed_timestamps + [None, 2099]:
    try:
        timestamp(value)
    except ValueError:
        pass
    else:
        raise AssertionError(f'malformed timestamp accepted: {value!r}')


def exercise(inventory=INVENTORY, state=STATE, budget=0, locked=False, inventory_mode=0o600,
             lock_mode=0o600, policy=None, ambient=None, show_policy=False):
    with tempfile.TemporaryDirectory(prefix='auto-cleanup-retention-', dir=os.environ['TMPDIR']) as scratch:
        root = Path(scratch)
        path = root / 'protection.json'
        if inventory is not None:
            path.write_text(inventory if isinstance(inventory, str) else json.dumps(inventory))
            path.chmod(inventory_mode)
        state_path = root / 'state.json'
        state_path.write_text(json.dumps(state))
        target = dict(name='retention-test', kind='rootless', user=pwd.getpwuid(os.geteuid()).pw_name,
                      socket='/run/user/1000/docker.sock', daemon_config=None, daemon_service=None, cache_gib=None,
                      schedule='daily', container_until='24h', network_until='24h', image_until='24h',
                      image_min_free_gib=budget, image_protection_mode='inventory', image_keep_tags=[],
                      image_protection_file=str(path))
        target.update(policy or {})
        config = root / 'target.json'
        config.write_text(json.dumps(target))
        binary = root / 'bin'
        binary.mkdir()
        (binary / 'docker').symlink_to(REPO / 'tests/fixtures/fake-retention-docker.py')
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   RETENTION_STATE=str(state_path), RETENTION_PROTECTION_FILE=str(path),
                   FAKE_DOCKER_LOG=str(root / 'log'), EXPECTED_DOCKER_ENDPOINT='unix://' + target['socket'])
        env.update(ambient or {})
        with Path(str(path) + '.lock').open('w') as lock:
            os.fchmod(lock.fileno(), lock_mode)
            if locked:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            command = [sys.executable, str(REPO / 'tests/fixtures/run-retention-case.py'), str(config)]
            if show_policy:
                command = [str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config), '--show-policy']
            result = subprocess.run(command, env=env,
                                    text=True, capture_output=True, timeout=15)
        log = (root / 'log').read_text() if (root / 'log').exists() else ''
        remaining = {image['Id'] for image in json.loads(state_path.read_text())['images']}
        assert 'image prune' not in log and 'volume' not in log and 'buildx' not in log
        return result, log, remaining


result, log, remaining = exercise()
assert result.returncode == 0, result.stderr
assert remaining == {CURRENT, YOUNG}, remaining
assert f'image rm --no-prune {OLD}' in log
assert 'network prune -f --filter until=24h' in log

result, log, remaining = exercise(policy={'network_until': None})
assert result.returncode == 0 and remaining == {CURRENT, YOUNG}, result.stderr
assert 'network ' not in log
assert 'container prune -f --filter until=24h --filter label=auto-cleanup.disposable=true' in log

state = dict(STATE, containers={'stopped-disposable': OLD}, disposable_containers=True)
result, log, remaining = exercise(state=state, policy={'network_until': None})
assert result.returncode == 0 and remaining == {CURRENT, OLD, YOUNG}, result.stderr
assert 'network ' not in log

for inputs in ({'locked': True}, {'inventory': None}, {'inventory': '{}'}):
    result, log, remaining = exercise(policy={'network_until': None}, **inputs)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log

selected = {'socket': '/run/user/1000/selected.sock'}
ambient = {'DOCKER_HOST': 'tcp://unrelated:2375', 'DOCKER_CONTEXT': 'unrelated',
           'DOCKER_TLS': '1', 'DOCKER_TLS_VERIFY': '1', 'DOCKER_CERT_PATH': '/unrelated'}
result, log, remaining = exercise(policy=selected, ambient=ambient)
assert result.returncode == 0 and remaining == {CURRENT, YOUNG}, result.stderr
result, log, remaining = exercise(policy=selected, show_policy=True)
assert result.returncode == 0 and not log and json.loads(result.stdout)['socket'] == selected['socket']
result, log, remaining = exercise(state=dict(STATE, daemon_down=True), policy=selected)
assert result.returncode != 0 and log.splitlines() == ['info --format {{json .}}']
assert remaining == {CURRENT, OLD, YOUNG} and selected['socket'] in result.stderr
for socket in ('', 'tcp://host:2375', 'relative.sock', '/', '/run/../docker.sock'):
    result, log, remaining = exercise(policy={'socket': socket})
    assert result.returncode != 0 and not log and remaining == {CURRENT, OLD, YOUNG}

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
for value in malformed_timestamps:
    inventory = copy.deepcopy(INVENTORY)
    inventory['expires_at'] = value
    invalid.append(inventory)
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

for value in malformed_timestamps:
    state = copy.deepcopy(STATE)
    state['images'][1]['Created'] = value
    result, log, remaining = exercise(state=state)
    assert result.returncode != 0 and 'image rm' not in log, (result.stderr, log)
    assert remaining == {CURRENT, OLD, YOUNG} and 'Traceback' not in result.stderr

state = copy.deepcopy(STATE)
state['images'] = state['images'][1:]
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and 'prune' not in log
state = copy.deepcopy(STATE)
# A container can reference an image absent from the local image store. Its
# reference still protects that ID; it does not block unrelated retention.
missing = 'sha256:' + 'f' * 64
state['containers'] = {'existing-container': missing}
result, log, remaining = exercise(state=state)
assert result.returncode == 0 and remaining == {CURRENT, YOUNG}, result.stderr
assert f'image inspect {missing}' not in log
assert f'image rm --no-prune {OLD}' in log
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

for network_until in ('24h', None):
    state = copy.deepcopy(STATE)
    state['change_inventory'] = True
    result, log, remaining = exercise(state=state, policy={'network_until': network_until})
    assert result.returncode != 0 and 'network prune' not in log and 'image rm' not in log

state = copy.deepcopy(STATE)
state['refuse_removal'] = True
result, log, remaining = exercise(state=state)
assert result.returncode != 0 and OLD in remaining

# Pressure can evict younger unprotected images, never protected images, and
# reports an unmet floor rather than claiming shared layers released bytes.
result, log, remaining = exercise(budget=999999)
assert result.returncode != 0 and remaining == {CURRENT}, (result.stderr, remaining)
assert 'Cannot meet' in result.stderr

# Modes without an inventory protect container identities and need no publisher.
for mode in ('none', 'tags'):
    options = {'image_protection_mode': mode}
    if mode == 'tags':
        options['image_keep_tags'] = [TAG]
    state = copy.deepcopy(STATE)
    state['containers'] = {'stopped': OLD, 'absent-source': missing}
    state['disposable_containers'] = True
    result, log, remaining = exercise(inventory=None, state=state, policy=options)
    expected = {OLD, YOUNG} | ({CURRENT} if mode == 'tags' else set())
    assert result.returncode == 0 and remaining == expected, (result.stderr, remaining)
    assert f'image inspect {missing}' not in log
    result, log, remaining = exercise(inventory=None, locked=True, policy=options)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log
    result, log, remaining = exercise(inventory=None, lock_mode=0o666, policy=options)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log
    expired = copy.deepcopy(INVENTORY)
    expired['expires_at'] = '2000-01-01T00:00:00Z'
    for unused_inventory, file_mode in [('{}', 0o600), (expired, 0o600),
                                        (INVENTORY, 0o666), (INVENTORY, 0o000)]:
        result, log, remaining = exercise(inventory=unused_inventory, inventory_mode=file_mode,
                                          policy=options)
        expected = {YOUNG} | ({CURRENT} if mode == 'tags' else set())
        assert result.returncode == 0 and remaining == expected, (result.stderr, remaining)

result, log, remaining = exercise(inventory=None, policy={'image_protection_mode': 'none'})
assert result.returncode == 0 and remaining == {YOUNG}, (result.stderr, remaining)
assert f'image rm --no-prune {CURRENT}' in log

# Failure of the final container scan stops subsequent deletion, even though
# genuine image-removal failures are reported while other candidates continue.
state = copy.deepcopy(STATE)
state['fail_container_list_at'] = 3
result, log, remaining = exercise(inventory=None, state=state,
                                  policy={'image_protection_mode': 'none'})
assert result.returncode != 0 and remaining == {CURRENT, OLD, YOUNG}, (result.stderr, remaining)
assert 'container ls -aq --no-trunc' in result.stderr and 'image rm' not in log
assert 'Traceback' not in result.stderr

# A selected local tag protects its image identity, including all other aliases.
state = copy.deepcopy(STATE)
state['images'][0]['RepoTags'].append('example.test/app:rollback')
state['images'][1]['RepoTags'] = ['example.test/app:old']
tag_options = {'image_protection_mode': 'tags', 'image_keep_tags': [TAG]}
result, log, remaining = exercise(inventory=None, state=state, policy=tag_options)
assert result.returncode == 0 and remaining == {CURRENT, YOUNG}, (result.stderr, remaining)
assert f'image rm --no-prune {CURRENT}' not in log
assert f'image inspect {TAG}' in log

result, log, remaining = exercise(inventory=None, state=state, policy={
    'image_protection_mode': 'tags', 'image_keep_tags': [TAG, 'example.test/app:old']})
assert result.returncode == 0 and remaining == {CURRENT, OLD, YOUNG}, (result.stderr, remaining)

result, log, remaining = exercise(inventory=None, budget=999999, policy=tag_options)
assert result.returncode != 0 and remaining == {CURRENT}, (result.stderr, remaining)
assert 'Cannot meet' in result.stderr

# A moved tag protects its current target; the old target becomes eligible
# unless a container still refers to it.
state = copy.deepcopy(STATE)
state.update(retarget_tag_after_container_lists=2, retarget_tag=TAG, retarget_to=OLD)
result, log, remaining = exercise(inventory=None, state=state, policy=tag_options)
assert result.returncode == 0 and remaining == {OLD, YOUNG}, (result.stderr, log, remaining)
assert f'image rm --no-prune {CURRENT}' in log
assert f'image rm --no-prune {OLD}' not in log

# Retarget between the first guard and the removal guard: the refreshed ID
# must be used, rather than merely resolving the changed tag and discarding it.
state = copy.deepcopy(STATE)
state.update(retarget_tag_after_container_lists=4, retarget_tag=TAG, retarget_to=OLD)
result, log, remaining = exercise(inventory=None, state=state, policy=tag_options)
assert result.returncode == 0 and OLD in remaining, (result.stderr, log, remaining)
assert f'image rm --no-prune {OLD}' not in log

# Exact local names cannot be replaced by a convenient inspect alias, and
# missing selected tags stop all pruning before the initial validation finishes.
for selected in ('example.test/app:missing', 'app:latest'):
    state = copy.deepcopy(STATE)
    if selected == 'app:latest':
        state['inspect_aliases'] = {selected: CURRENT}
    result, log, remaining = exercise(inventory=None, state=state, policy={
        'image_protection_mode': 'tags', 'image_keep_tags': [selected]})
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log
    assert selected in result.stderr and 'Traceback' not in result.stderr

for network_until in ('24h', None):
    state = copy.deepcopy(STATE)
    state['remove_tag_on_container_prune'] = TAG
    result, log, remaining = exercise(inventory=None, state=state, policy=dict(tag_options, network_until=network_until))
    assert result.returncode != 0 and 'container prune' in log
    assert 'network prune' not in log and 'image rm' not in log

state = copy.deepcopy(STATE)
state['malformed_inspect'] = True
result, log, remaining = exercise(inventory=None, state=state, policy=tag_options)
assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log
assert 'cannot resolve one image object' in result.stderr and 'Traceback' not in result.stderr

for malformed_tags in (TAG, {TAG: 'alias'}, [TAG, 7]):
    state = copy.deepcopy(STATE)
    state['images'][0]['RepoTags'] = malformed_tags
    result, log, remaining = exercise(inventory=None, state=state, policy=tag_options)
    assert result.returncode != 0 and 'prune' not in log and 'image rm' not in log
    assert 'RepoTags' in result.stderr and 'Traceback' not in result.stderr

invalid_options = [
    {'image_protection_mode': ''},
    {'image_protection_mode': 'unknown'},
    {'image_protection_mode': 'tags'},
    {'image_protection_mode': 'tags', 'image_keep_tags': []},
    {'image_protection_mode': 'none', 'image_keep_tags': [TAG]},
    {'image_protection_mode': 'inventory', 'image_keep_tags': [TAG]},
]
for reference in ('example.test/app', 'registry:5000/app', DIGEST, CURRENT, 'example.test/app:'):
    invalid_options.append({'image_protection_mode': 'tags', 'image_keep_tags': [reference]})
for options in invalid_options:
    result, log, remaining = exercise(policy=options)
    assert result.returncode != 0 and not log, (options, result.stderr, log)
    assert ('image_' in result.stderr or 'tags mode' in result.stderr) and 'Traceback' not in result.stderr

# Empty tag lists are valid outside tags mode; this test target explicitly selects inventory.
for mode in ('none', 'inventory'):
    result, log, remaining = exercise(policy={
        'image_protection_mode': mode, 'image_keep_tags': []})
    assert result.returncode == 0, result.stderr
result, log, remaining = exercise(inventory=None)
assert result.returncode != 0 and 'prune' not in log

# Reporting the selected policy requires no Docker daemon or inventory read.
for mode in ('none', 'tags', 'inventory'):
    options = {'image_protection_mode': mode}
    if mode == 'tags':
        options['image_keep_tags'] = [TAG, 'example.test/app:rollback']
    result, log, remaining = exercise(inventory=None, policy=options, show_policy=True)
    assert result.returncode == 0 and not log, (result.stderr, log)
    assert json.loads(result.stdout)['image_protection_mode'] == mode
    if mode == 'tags':
        assert json.loads(result.stdout)['image_keep_tags'] == options['image_keep_tags']

print('image retention ok')
