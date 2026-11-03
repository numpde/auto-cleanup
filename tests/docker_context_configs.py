"""Config discovery preserves reviewed policies and rejects conflicting targets."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import socket
import tempfile
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
module = runpy.run_path(str(REPO / 'scripts/docker-context-configs.py'))
main = module['main']
check = module['check']
globals_ = main.__globals__

with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    endpoint = root / 'docker.sock'
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(endpoint))
        contexts = [{'Name': 'engine', 'Endpoints': {'docker': {'Host': 'unix://' + str(endpoint)}}}]

        def docker(*args):
            if args[:2] == ('context', 'ls'):
                return 'engine\n'
            if args[:2] == ('context', 'inspect'):
                return json.dumps(contexts)
            return json.dumps({'ID': 'engine-id', 'SecurityOptions': ['name=rootless']})

        with patch.dict(globals_, docker=docker), contextlib.redirect_stdout(io.StringIO()):
            assert main(root / 'configs') == 0
            path = root / 'configs/engine.json'
            config = json.loads(path.read_text())
            config['image_until'] = '720h'
            path.write_text(json.dumps(config))
            before = path.read_bytes()
            assert main(path.parent) == 0
            assert path.read_bytes() == before
            second = dict(config, name='other', socket=str(root / 'other.sock'))
            (path.parent / 'other.json').write_text(json.dumps(second))
            ids = iter(('engine-id', 'other-id'))

            def info(*args):
                return json.dumps({'ID': next(ids), 'SecurityOptions': ['name=rootless']})

            with patch.dict(globals_, docker=info, verify_socket_owner=lambda *_: None), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                assert check(path.parent) == 1
                assert 'managed path overlaps' in errors.getvalue()
            second.update(user='root', kind='rootful',
                          image_protection_file=str(Path(config['image_protection_file']).parent / 'other.json'))
            (path.parent / 'other.json').write_text(json.dumps(second))
            identities = iter((('engine-id', ['name=rootless']), ('other-id', [])))

            def mixed_info(*args):
                daemon, security = next(identities)
                return json.dumps({'ID': daemon, 'SecurityOptions': security})

            with patch.dict(globals_, docker=mixed_info, verify_socket_owner=lambda *_: None), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                assert check(path.parent) == 1
                assert 'protection directories overlap' in errors.getvalue()
            path.write_text(json.dumps(config))
            second = dict(config, name='other', socket=str(root / 'other.sock'),
                          image_protection_file=str(Path(config['image_protection_file']).parent / 'other.json'))
            (path.parent / 'other.json').write_text(json.dumps(second))
            identities = iter((('engine-id', ['name=rootless']), ('other-id', ['name=rootless'])))
            with patch.dict(globals_, docker=mixed_info, verify_socket_owner=lambda *_: None):
                assert check(path.parent) == 0
            second['image_protection_file'] = str(Path(config['image_protection_file']).parent / 'nested/other.json')
            (path.parent / 'other.json').write_text(json.dumps(second))
            identities = iter((('engine-id', ['name=rootless']), ('other-id', ['name=rootless'])))
            with patch.dict(globals_, docker=mixed_info, verify_socket_owner=lambda *_: None), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                assert check(path.parent) == 1
                assert 'protection directories overlap' in errors.getvalue()
            first = dict(config, user='root', kind='rootful',
                         image_protection_file=str(Path(config['image_protection_file']).parent / 'nested/first.json'))
            second = dict(config, name='other', socket=str(root / 'other.sock'))
            path.write_text(json.dumps(first))
            (path.parent / 'other.json').write_text(json.dumps(second))
            identities = iter((('engine-id', []), ('other-id', ['name=rootless'])))
            with patch.dict(globals_, docker=mixed_info, verify_socket_owner=lambda *_: None), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                assert check(path.parent) == 1
                assert 'protection directories overlap' in errors.getvalue()
            path.write_text(json.dumps(config))
            second.update(user='root', kind='rootful', image_protection_file=str(
                Path(config['image_protection_file']).parent / 'nested/other.json'))
            (path.parent / 'other.json').write_text(json.dumps(second))
            identities = iter((('engine-id', ['name=rootless']), ('other-id', [])))
            with patch.dict(globals_, docker=mixed_info, verify_socket_owner=lambda *_: None), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                assert check(path.parent) == 1
                assert 'protection directories overlap' in errors.getvalue()
print('Docker context configs ok')
