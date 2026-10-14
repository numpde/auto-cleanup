"""Enrollment, updates and removal preserve independent maintenance owners."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / 'scripts/auto-cleanup'


def invoke(root, *args, good=True):
    result = subprocess.run([str(CLI), *args, '--root', str(root)], text=True, capture_output=True, timeout=30)
    assert (result.returncode == 0) == good, (args, result.stdout, result.stderr)
    return result


def target(name, rootless=False):
    return dict(name=name, kind='rootless' if rootless else 'rootful', user='test-runner' if rootless else 'root',
                socket='/run/user/65532/docker.sock' if rootless else '/var/run/docker.sock',
                daemon_config=None, daemon_service=None, cache_gib=None, schedule='daily',
                container_until='24h', network_until='24h', image_until='168h', image_min_free_gib=0,
                image_protection_mode='none', image_keep_tags=[],
                image_protection_file=f'/var/lib/auto-cleanup/{name}/images.json')


with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as scratch:
    scratch = Path(scratch)
    root = scratch / 'stage'
    configs = {}
    for name, rootless in [('traefik', False), ('agent-mail', True)]:
        config = scratch / (name + '.json')
        config.write_text(json.dumps(target(name, rootless)))
        configs[name] = config
        before = sorted(str(path.relative_to(root)) for path in root.rglob('*'))
        invoke(root, 'docker', 'install', '--config', str(config), '--dry-run')
        assert sorted(str(path.relative_to(root)) for path in root.rglob('*')) == before, 'dry run created managed paths'
        invoke(root, 'docker', 'install', '--config', str(config))
        invoke(root, 'docker', 'check', name)
    invalid_root = scratch / 'invalid-restart'
    invoke(invalid_root, 'docker', 'install', '--config', str(configs['agent-mail']), '--restart-docker', good=False)
    assert not invalid_root.exists(), 'invalid restart option changed managed files'
    collision = scratch / 'collision.json'
    collision.write_text(json.dumps(dict(target('collision'), socket='/run/collision.sock',
        daemon_config='/etc/auto-cleanup/docker/agent-mail.json', daemon_service='docker.service', cache_gib=1)))
    invoke(root, 'docker', 'install', '--config', str(collision), good=False)
    executable = root / 'usr/local/lib/auto-cleanup/docker-clean'
    executable.chmod(0o644)
    invoke(root, 'docker', 'check', 'agent-mail', good=False)
    executable.chmod(0o755)
    listing = invoke(root, 'docker', 'list').stdout
    assert 'agent-mail rootless test-runner' in listing and 'traefik rootful root' in listing
    registered = root / 'etc/auto-cleanup/docker/agent-mail.json'
    data = json.loads(registered.read_text())
    data['image_until'] = '336h'
    registered.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    invoke(root, 'docker', 'install', 'agent-mail')
    assert json.loads(registered.read_text())['image_until'] == '336h'
    invoke(root, 'docker', 'check', 'agent-mail')
    duplicate = scratch / 'duplicate.json'
    duplicate.write_text(json.dumps(target('duplicate', True)))
    before = registered.read_bytes()
    invoke(root, 'docker', 'install', '--config', str(duplicate), good=False)
    assert not (root / 'etc/auto-cleanup/docker/duplicate.json').exists() and registered.read_bytes() == before
    nested = dict(target('nested', True), socket='/run/nested.sock',
                  image_protection_file=data['image_protection_file'] + '/nested/images.json')
    duplicate.write_text(json.dumps(nested))
    invoke(root, 'docker', 'install', '--config', str(duplicate), good=False)
    assert not (root / data['image_protection_file'].lstrip('/')).exists()
    changed = dict(data, socket='/run/user/65532/other.sock')
    configs['agent-mail'].write_text(json.dumps(changed))
    invoke(root, 'docker', 'install', '--config', str(configs['agent-mail']), good=False)
    host = scratch / 'host.json'
    host.write_text(json.dumps(dict(journald=True, apt=False, btmp=False)))
    invoke(root, 'host', 'install', '--config', str(host))
    invoke(root, 'host', 'check')
    invoke(root, 'host', 'install')
    missing = scratch / 'missing-host.json'
    invoke(scratch / 'missing-host-stage', 'host', 'install', '--config', str(missing), good=False)
    assert not (scratch / 'missing-host-stage').exists()
    invoke(root, 'host', 'remove', '--config', str(host), good=False)
    assert not (root / 'etc/apt').exists() and not (root / 'etc/logrotate.d').exists()
    invoke(root, 'docker', 'remove', 'traefik')
    assert registered.exists() and (root / 'usr/local/lib/auto-cleanup/docker-clean').exists()
    invoke(root, 'docker', 'check', 'agent-mail')
    invoke(root, 'host', 'remove')
    assert registered.exists() and not (root / 'etc/systemd/journald.conf.d/auto-cleanup-limits.conf').exists()
    invoke(root, 'docker', 'remove', 'agent-mail')
    assert not (root / 'usr/local/lib/auto-cleanup/docker-clean').exists()
    assert (root / 'var/lib/auto-cleanup/agent-mail').exists(), 'stable state directory was removed'
    legacy = root / 'etc/systemd/system/vps-docker-clean.service'
    legacy.write_text('[Service]\n')
    invoke(root, 'docker', 'install', '--config', str(configs['traefik']), good=False)
    managed_root = scratch / 'managed-stage'
    daemon = managed_root / 'etc/docker/daemon.json'
    daemon.parent.mkdir(parents=True)
    daemon.write_text('{"data-root":"/kept","debug":true}\n')
    daemon.chmod(0o600)
    managed = scratch / 'managed.json'
    managed.write_text(json.dumps(dict(target('managed'), daemon_config='/etc/docker/daemon.json',
                                       daemon_service='docker.service', cache_gib=2)))
    invoke(managed_root, 'docker', 'install', '--config', str(managed))
    invoke(managed_root, 'docker', 'check', 'managed')
    policy = json.loads(daemon.read_text())
    assert policy['data-root'] == '/kept' and policy['debug'] is True
    assert policy['builder']['gc']['policy'][0]['maxUsedSpace'] == '2GB'
    assert daemon.stat().st_mode & 0o777 == 0o600 and list(daemon.parent.glob('*.bak.*'))
print('target lifecycle ok')
