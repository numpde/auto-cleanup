"""Configured execution honors root config trust and daemon-owner state trust."""
import json
import os
from pathlib import Path
import subprocess
import socket
import sys
import select

REPO = Path(__file__).resolve().parents[1]
kind = 'rootful' if os.geteuid() == 0 else 'rootless'
config = REPO / f'tests/fixtures/target-{kind}.json'
settings = json.loads(config.read_text())
root = Path(settings['image_protection_file']).parent
root.mkdir(parents=True, exist_ok=True)
listener = socket.socket(socket.AF_UNIX)
socket_path = Path(settings['socket'])
if socket_path.exists():
    socket_path.unlink()
listener.bind(str(socket_path))
binary = root / 'bin'
binary.mkdir(exist_ok=True)
if not (binary / 'docker').exists():
    (binary / 'docker').symlink_to(REPO / 'tests/fixtures/fake-retention-docker.py')
current = 'sha256:' + 'a' * 64
old = 'sha256:' + 'b' * 64
digest = 'example.test/app@sha256:' + 'd' * 64
inventory = dict(version=1, daemon_id='test-daemon', expires_at='2099-01-01T00:00:00Z',
                 deployments={'app': {'current': [digest], 'rollback': []}}, recovery=[])
Path(settings['image_protection_file']).write_text(json.dumps(inventory))
Path(settings['image_protection_file']).chmod(0o600)
state = dict(images=[dict(Id=current, RepoDigests=[digest], Created='2020-01-01T00:00:00Z'),
                     dict(Id=old, Created='2020-01-01T00:00:00Z')], containers={},
             security_options=['name=rootless'] if kind == 'rootless' else [])
env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
           RETENTION_STATE=str(root / 'state.json'), FAKE_DOCKER_LOG=str(root / 'log'),
           EXPECTED_DOCKER_ENDPOINT='unix://' + settings['socket'], IMAGE_PROTECTION_MODE='none',
           RETENTION_PROTECTION_FILE=settings['image_protection_file'])


def run(changed=None):
    (root / 'state.json').write_text(json.dumps(dict(state, **(changed or {}))))
    if (root / 'log').exists():
        (root / 'log').unlink()
    result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config)],
                            env=env, text=True, capture_output=True, timeout=15)
    log = (root / 'log').read_text() if (root / 'log').exists() else ''
    return result, log


result, log = run()
assert result.returncode == 0 and f'image rm --no-prune {old}' in log, result.stderr
assert [image['Id'] for image in json.loads((root / 'state.json').read_text())['images']] == [current]
assert Path(str(settings['image_protection_file']) + '.lock').stat().st_uid == os.geteuid()
result, log = run(dict(security_options=[] if kind == 'rootless' else ['name=rootless']))
assert result.returncode != 0 and 'does not match' in result.stderr and 'prune' not in log
result, log = run(dict(daemon_down=True))
assert result.returncode != 0 and log.splitlines() == ['info --format {{json .}}']
Path(settings['image_protection_file']).chmod(0o666)
result, log = run()
assert result.returncode != 0 and 'writable' in result.stderr and 'prune' not in log
other_config = REPO / f"tests/fixtures/target-{'rootless' if kind == 'rootful' else 'rootful'}.json"
result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(other_config)],
                        env=env, text=True, capture_output=True, timeout=15)
assert result.returncode != 0 and 'must run as' in result.stderr, result.stderr

# Exercise the installed CLI's admission and the real descriptor inherited by
# a shell. The held stdin is an observed barrier, not a timing assumption.
Path(settings['image_protection_file']).chmod(0o600)
guard = [str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config),
         '--run-locked', '--endpoint', 'unix://' + settings['socket'], '--']
holder = subprocess.Popen(guard + ['sh', '-c', 'printf "held\\n"; read answer; exit 23'],
                          env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
try:
    assert select.select([holder.stdout], [], [], 10)[0], 'guarded command did not reach its barrier'
    assert holder.stdout.readline() == 'held\n'
    result, log = run()
    assert result.returncode != 0 and 'busy' in result.stderr, result.stderr
    assert 'prune' not in log and 'image rm' not in log, log
finally:
    output, error = holder.communicate('release\n', timeout=10)
assert holder.returncode == 23, (holder.returncode, output, error)
result, log = run()
assert result.returncode == 0, result.stderr

result = subprocess.run(guard + guard + ['sh', '-c', 'exit 19'], env=env,
                        text=True, capture_output=True, timeout=10)
assert result.returncode == 19, result.stderr
literal = '$(touch /tmp/auto-cleanup-must-not-execute)'
result = subprocess.run(guard + [sys.executable, '-c', 'import sys; print(sys.argv[1])', literal],
                        env=env, text=True, capture_output=True, timeout=10)
assert result.returncode == 0 and result.stdout.strip() == literal, result.stderr

for arguments in (guard[:-1], [*guard[:5], 'unix:///different.sock', '--', 'sh', '-c', 'echo started']):
    result = subprocess.run(arguments, env=env, text=True, capture_output=True, timeout=10)
    assert result.returncode != 0 and 'guarded operation' in result.stderr, result.stderr
    assert not result.stdout and 'may be partial' not in result.stderr

for changed in ({'AUTO_CLEANUP_LOCK_FD': '9999'}, {'AUTO_CLEANUP_LOCK_FD': 'not-a-descriptor'}):
    result = subprocess.run(guard + ['sh', '-c', 'echo started'], env=dict(env, **changed),
                            text=True, capture_output=True, timeout=10)
    assert result.returncode != 0 and not result.stdout, result.stderr

lock_path = Path(settings['image_protection_file'] + '.lock')
lock_path.chmod(0o666)
result = subprocess.run(guard + ['sh', '-c', 'echo started'], env=env,
                        text=True, capture_output=True, timeout=10)
assert result.returncode != 0 and not result.stdout and 'writable' in result.stderr
lock_path.unlink()
lock_path.symlink_to(settings['image_protection_file'])
result = subprocess.run(guard + ['sh', '-c', 'echo started'], env=env,
                        text=True, capture_output=True, timeout=10)
assert result.returncode != 0 and not result.stdout, result.stderr
lock_path.unlink()
print(f'{kind} configured execution ok')
listener.close()
socket_path.unlink()
