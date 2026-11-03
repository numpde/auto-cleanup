#!/usr/bin/env python3
"""Create reviewable cleanup configurations for local Docker contexts."""
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures/bin'))
from auto_cleanup_config import load_target, validate_target, verify_socket_owner


def docker(*args):
    return subprocess.run(['docker', *args], text=True, capture_output=True,
                          timeout=30, check=True).stdout


def daemon_identity(info):
    daemon = info['ID']
    security = info['SecurityOptions']
    if not isinstance(daemon, str) or not daemon:
        raise ValueError('daemon identity is missing')
    if not isinstance(security, list) or any(not isinstance(value, str) for value in security):
        raise ValueError('daemon security options are invalid')
    return daemon, 'name=rootless' in security


def main(directory):
    names = docker('context', 'ls', '--format', '{{.Name}}').splitlines()
    contexts = json.loads(docker('context', 'inspect', *names))
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    print('Creating configs for accessible local Docker contexts; existing files are preserved.')
    print('Defaults: daily, containers 24h, images 168h, networks untouched, no extra image protection.')
    print('WARNING: unused images older than seven days can be removed, including rollback images.')
    failed = False
    seen = set()
    for context in contexts:
        name = context.get('Name', '<unnamed>') if isinstance(context, dict) else '<invalid>'
        try:
            endpoint = context['Endpoints']['docker']['Host']
            if not isinstance(endpoint, str):
                raise ValueError('Docker endpoint is invalid')
            if not endpoint.startswith('unix:///'):
                print(f'Skip {name}: not a local Unix socket')
                continue
            socket = endpoint[len('unix://'):]
            metadata = os.stat(socket)
            if not stat.S_ISSOCK(metadata.st_mode):
                raise ValueError('endpoint is not a socket')
            user = pwd.getpwuid(metadata.st_uid).pw_name
            info = json.loads(docker('--context', name, 'info', '--format', '{{json .}}'))
            daemon, rootless = daemon_identity(info)
            if daemon in seen:
                raise ValueError('daemon already selected by another context')
            kind = 'rootless' if rootless else 'rootful'
            target = dict(name=name, kind=kind, user=user, socket=socket, daemon_config=None,
                          daemon_service=None, cache_gib=None, schedule='daily', container_until='24h',
                          network_until=None, image_until='168h', image_min_free_gib=0,
                          image_protection_mode='none', image_keep_tags=[],
                          image_protection_file=f'/opt/auto-cleanup/state/{name}/images.json')
            validate_target(target)
            path = directory / f'{name}.json'
            if path.exists() or path.is_symlink():
                existing = load_target(path)
                if any(existing[key] != target[key] for key in ('name', 'kind', 'user', 'socket')):
                    raise ValueError('existing config identity differs from the context')
                seen.add(daemon)
                print(f'Preserved {path}; existing policy was not changed')
                continue
            with path.open('x') as stream:
                json.dump(target, stream, indent=2)
                stream.write('\n')
            path.chmod(0o600)
            seen.add(daemon)
            print(f'Created {path} ({kind}, account {user}, socket {socket})')
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f'Cannot create config for {name}: {error}', file=sys.stderr)
            failed = True
    print(f'Check and review every JSON file in {directory} before installation:')
    print(f'  make docker/configs/check CONFIG_DIR={directory}')
    print('Edit policies or remove unwanted files, then follow the README instructions')
    print('to use a root-owned checkout and protected config copies for installation.')
    return 1 if failed else 0


def check(directory):
    files = sorted(directory.glob('*.json'))
    if not files:
        raise ValueError(f'no JSON configs in {directory}')
    failed = False
    seen = set()
    managed_paths = []
    state_owners = {}
    for path in files:
        try:
            target = load_target(path)
            if path.stem != target['name']:
                raise ValueError('filename does not match configured name')
            uid = pwd.getpwnam(target['user']).pw_uid
            verify_socket_owner(target, uid)
            info = json.loads(docker('--host', 'unix://' + target['socket'], 'info', '--format', '{{json .}}'))
            daemon, rootless = daemon_identity(info)
            if daemon in seen:
                raise ValueError('daemon already selected by another config')
            if rootless != (target['kind'] == 'rootless'):
                raise ValueError('daemon kind does not match config')
            paths = [Path(value) for value in (target['daemon_config'], target['image_protection_file'],
                                                target['image_protection_file'] + '.lock') if value]
            state_dir = Path(target['image_protection_file']).parent
            for other_dir, owner in state_owners.items():
                conflict = ((state_dir == other_dir and owner != uid) or
                            state_dir in other_dir.parents or other_dir in state_dir.parents)
                if conflict:
                    raise ValueError('protection directories overlap or require different owners')
            for index, managed_path in enumerate(paths):
                for other, other_name in managed_paths + [(p, target['name']) for p in paths[:index]]:
                    if managed_path == other or managed_path in other.parents or other in managed_path.parents:
                        raise ValueError(f'managed path overlaps config {other_name}')
            seen.add(daemon)
            managed_paths.extend((value, target['name']) for value in paths)
            state_owners[state_dir] = uid
            print(f"OK {path}: user={target['user']} socket={target['socket']} schedule={target['schedule']}")
            print(f"  containers={target['container_until']} networks={target['network_until']} "
                  f"images={target['image_until']} protection={target['image_protection_mode']} "
                  f"tags={json.dumps(target['image_keep_tags'])} inventory={target['image_protection_file']}")
            print(f"  daemon_config={target['daemon_config']} daemon_service={target['daemon_service']} cache_gib={target['cache_gib']} "
                  f"minimum_free_gib={target['image_min_free_gib']}")
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f'Cannot check {path}: {error}', file=sys.stderr)
            failed = True
    print('Config checks do not verify protected tags or inventories, establish systemd compatibility,')
    print('or authorize cleanup. Run the installation preview and review protection separately.')
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(check(Path(sys.argv[2])) if sys.argv[1] == '--check' else main(Path(sys.argv[1])))
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print(f'Cannot discover Docker contexts: {error}', file=sys.stderr)
        sys.exit(1)
