#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

echo "syntax"

for script in \
    "$REPO_DIR/scripts/install.sh" \
    "$REPO_DIR/scripts/check.sh" \
    "$REPO_DIR/scripts/uninstall.sh" \
    "$REPO_DIR/scripts/lib/common.sh" \
    "$REPO_DIR/scripts/lib/policy.sh" \
    "$REPO_DIR/tests/check-manifest.sh" \
    "$REPO_DIR/tests/run-all.sh" \
    "$REPO_DIR/tests/00_syntax.sh" \
    "$REPO_DIR/tests/01_manifest.sh" \
    "$REPO_DIR/tests/02_container_posture.sh" \
    "$REPO_DIR/tests/30_functionality.sh" \
    "$REPO_DIR/tests/34_daemon_json.sh" \
    "$REPO_DIR/tests/35_profiles.sh" \
    "$REPO_DIR/tests/41_native_btmp.sh" \
    "$REPO_DIR/tests/39_native_apt.sh" \
    "$REPO_DIR/tests/38_policy_integrity.sh" \
    "$REPO_DIR/tests/37_image_retention.sh" \
    "$REPO_DIR/tests/36_install_progress.sh" \
    "$REPO_DIR/tests/40_docs_contract.sh" \
    "$REPO_DIR/tests/root-metadata.sh" \
    "$REPO_DIR/tests/fixtures/fake-dockerd.sh" \
    "$REPO_DIR/tests/lib/require-container.sh" \
    "$REPO_DIR/tests/fixtures/fake-docker.sh"
do
    /bin/sh -n "$script"
    dash -n "$script"
done

bash -n "$REPO_DIR/scripts/test-container.sh"

python3 - "$REPO_DIR/lib/merge-docker-daemon.py" "$REPO_DIR/lib/apt-cleanup-policy.py" "$REPO_DIR/lib/btmp-policy.py" "$REPO_DIR/fixtures/bin/vps-docker-clean" "$REPO_DIR/tests/image_retention.py" "$REPO_DIR/tests/fixtures/fake-retention-docker.py" <<'PY'
import pathlib
import sys

for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

echo "syntax ok"
