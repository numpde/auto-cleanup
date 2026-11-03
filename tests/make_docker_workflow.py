"""Batch preview failures do not start installs; checks use the installed registry."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    shutil.copyfile(REPO / 'Makefile', root / 'Makefile')
    (root / 'scripts').mkdir()
    (root / 'fixtures/bin').mkdir(parents=True)
    (root / 'fixtures/bin/auto_cleanup_config.py').write_text(
        'import json\ndef load_target(path, trusted=False):\n'
        '    assert trusted\n    return json.load(open(path))\n')
    (root / 'scripts/docker-context-configs.py').write_text('print("config check")\n')
    cli = root / 'scripts/auto-cleanup'
    cli.write_text('''#!/usr/bin/env python3
import os, sys
with open(os.environ['EVENTS'], 'a') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['docker', 'list']:
    print('alpha rootless user /socket/a')
    print('beta rootless user /socket/b')
elif '--dry-run' in sys.argv and sys.argv[sys.argv.index('--config') + 1].endswith('beta.json'):
    sys.exit(1)
''')
    cli.chmod(0o755)
    configs = root / 'configs'
    configs.mkdir()
    for name in ('alpha', 'beta'):
        (configs / f'{name}.json').write_text(json.dumps({'name': name}))
    events = root / 'events'
    env = dict(os.environ, EVENTS=str(events))
    run = subprocess.run(['make', 'docker/install', f'CONFIG_DIR={configs}'], cwd=root,
                         env=env, capture_output=True, text=True)
    assert run.returncode != 0, run.stdout
    lines = events.read_text().splitlines()
    assert len(lines) == 2 and all('--dry-run' in line for line in lines), lines
    events.unlink()
    run = subprocess.run(['make', 'docker/check', f'CONFIG_DIR={root / "missing"}'], cwd=root,
                         env=env, capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    assert events.read_text().splitlines() == [
        'docker list', 'docker check alpha --live', 'docker check beta --live']
print('Docker Make workflow ok')
