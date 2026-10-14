"""Target policy is explicit and cannot be redirected by ambient settings."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'fixtures/bin'))
from auto_cleanup_config import validate_target

TARGET = dict(name='agent-mail', kind='rootless', user='test-runner',
              socket='/run/user/65532/docker.sock', daemon_config=None,
              daemon_service=None, schedule='daily', cache_gib=None,
              container_until='24h', network_until='24h', image_until='168h',
              image_min_free_gib=0, image_protection_mode='none', image_keep_tags=[],
              image_protection_file='/var/lib/auto-cleanup/agent-mail/images.json')
assert validate_target(TARGET) == TARGET
for example in ('rootful', 'agent-mail'):
    assert validate_target(json.loads((REPO / f'examples/{example}.json').read_text()))
for key, value in [('socket', 'tcp://host:2375'), ('name', '../other'), ('user', 'root'),
                   ('kind', 'auto'), ('cache_gib', True), ('cache_gib', 0),
                   ('schedule', 'hourly'), ('daemon_service', 'docker.service;bad'),
                   ('image_until', '0h'), ('image_until', '999999999999999999999h'), ('image_protection_mode', 'unknown'),
                   ('image_keep_tags', ['app:latest']), ('daemon_config', '/home/../etc/docker.json')]:
    changed = dict(TARGET, **{key: value})
    try:
        validate_target(changed)
    except ValueError:
        pass
    else:
        raise AssertionError(f'accepted invalid target: {key}={value!r}')
for changed in (dict(TARGET, network_until='3000000h'),
                dict(TARGET, image_protection_mode='tags', image_keep_tags=['repo:tag@bad'])):
    try:
        validate_target(changed)
    except ValueError:
        pass
    else:
        raise AssertionError(f'accepted invalid policy {changed}')
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as scratch:
    config = Path(scratch) / 'target.json'
    config.write_text(json.dumps(TARGET))
    env = dict(os.environ, IMAGE_UNTIL='1h', IMAGE_PROTECTION_MODE='inventory',
               AUTO_CLEANUP_DOCKER_SOCKET='/wrong.sock', IMAGE_KEEP_TAGS='wrong:tag')
    result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config), '--show-policy'],
                            env=env, text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
    assert 'IMAGE_UNTIL=168h' in result.stdout and 'IMAGE_PROTECTION_MODE=none' in result.stdout
    assert 'unix:///run/user/65532/docker.sock' in result.stdout and '/wrong.sock' not in result.stdout
    result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config)],
                            text=True, capture_output=True, timeout=15)
    assert result.returncode != 0 and 'root-owned' in result.stderr, result.stderr
    config.write_text('{"name":"first","name":"second"}')
    result = subprocess.run([str(REPO / 'fixtures/bin/vps-docker-clean'), '--config', str(config), '--show-policy'],
                            text=True, capture_output=True, timeout=15)
    assert result.returncode != 0 and 'duplicate' in result.stderr, result.stderr
print('target configuration ok')
