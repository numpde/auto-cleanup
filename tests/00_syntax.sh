#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
for script in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/tests/*.sh "$REPO_DIR"/tests/lib/*.sh; do
    case "$script" in */test-container.sh) continue ;; esac
    /bin/sh -n "$script"
    dash -n "$script"
done
bash -n "$REPO_DIR/scripts/test-container.sh"
python3 - "$REPO_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = list(root.rglob('*.py')) + [root / 'scripts/auto-cleanup', root / 'fixtures/bin/vps-docker-clean']
for path in paths:
    compile(path.read_text(), str(path), 'exec')
PY
echo 'syntax ok'
