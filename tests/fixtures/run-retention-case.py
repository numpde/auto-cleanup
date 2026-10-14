"""Exercise retention effects after admission, with a validated test-owned target.

Full root-owned config and socket admission are covered by target_runtime.py.
This entrypoint never ships in the installed runtime.
"""
import json
from pathlib import Path
import runpy
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'fixtures/bin'))
from auto_cleanup_config import load_target

try:
    target = load_target(sys.argv[1])
    cleanup = runpy.run_path(str(REPO / 'fixtures/bin/vps-docker-clean'))['run_cleanup']
    sys.exit(cleanup(target))
except (OSError, ValueError, KeyError, TypeError, OverflowError, RuntimeError, subprocess.TimeoutExpired) as error:
    print(f'Cannot complete Docker cleanup: {error}', file=sys.stderr)
    sys.exit(1)
