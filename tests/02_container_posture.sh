#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

echo "container posture"

wrapper="$REPO_DIR/scripts/test-container.sh"
containerfile="$REPO_DIR/containers/test/Containerfile"

require_text() {
    file=$1
    text=$2
    if ! grep -Fq -- "$text" "$file"; then
        echo "missing expected text in $file: $text" >&2
        exit 1
    fi
}

require_line() {
    text=$1
    line=$2
    if ! printf '%s\n' "$text" | grep -Fxq -- "$line"; then
        echo "missing expected argv line: $line" >&2
        exit 1
    fi
}

reject_text() {
    file=$1
    text=$2
    if grep -Fq -- "$text" "$file"; then
        echo "forbidden text in $file: $text" >&2
        exit 1
    fi
}

broad_argv=$("$wrapper" inspect/test)
root_argv=$("$wrapper" inspect/root-container)

require_line "$broad_argv" "--network"
require_line "$broad_argv" "none"
require_line "$broad_argv" "--read-only"
require_line "$broad_argv" "--cap-drop"
require_line "$broad_argv" "ALL"
require_line "$broad_argv" "--security-opt"
require_line "$broad_argv" "no-new-privileges:true"
require_line "$broad_argv" "--pull=never"
require_line "$broad_argv" "--user"
require_line "$broad_argv" "65532:65532"
require_line "$broad_argv" "--pids-limit"
require_line "$broad_argv" "--memory"
require_line "$broad_argv" "--memory-swap"
require_line "$broad_argv" "--tmpfs"
require_line "$broad_argv" "/tmp:rw,nosuid,nodev,noexec,size=256m,mode=1777"
require_line "$broad_argv" "AUTO_CLEANUP_TEST_CONTAINER=1"

require_line "$root_argv" "--user"
require_line "$root_argv" "0:0"
require_line "$root_argv" "--network"
require_line "$root_argv" "none"
require_line "$root_argv" "--read-only"
require_line "$root_argv" "--cap-drop"
require_line "$root_argv" "ALL"
require_line "$root_argv" "--cap-add"
require_line "$root_argv" "CHOWN"
require_line "$root_argv" "FOWNER"
require_line "$root_argv" "AUTO_CLEANUP_TEST_CONTAINER=1"
require_line "$root_argv" "AUTO_CLEANUP_TEST_ROOT_CONTAINER=1"
require_text "$wrapper" "AUTO_CLEANUP_ALLOW_ROOT_TESTS"
require_text "$wrapper" "DOCKER_CLI:-docker"
reject_text "$wrapper" "/var/run/docker.sock"
reject_text "$wrapper" "type=bind,src=\${root_dir}"
reject_text "$wrapper" "--privileged"
reject_text "$wrapper" "--env-file"
reject_text "$wrapper" "SSH_AUTH_SOCK"
reject_text "$wrapper" "AWS_"
reject_text "$wrapper" "CLOUDSDK_"
reject_text "$wrapper" "DOCKER_CONFIG"

require_text "$containerfile" "@sha256:"
require_text "$containerfile" "COPY . /work"
require_text "$containerfile" "PYTHONDONTWRITEBYTECODE=1"
reject_text "$containerfile" "docker.io/library/docker"
reject_text "$containerfile" "apt-get install -y docker"

if [ "$(id -u)" = "0" ]; then
    echo "broad test lane must not run as root" >&2
    exit 1
fi
if awk '$2 == "00000000" && $1 != "lo" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/route; then
    echo "default network route is present" >&2
    exit 1
fi
if [ -e /var/run/docker.sock ]; then
    echo "Docker socket is visible in test container" >&2
    exit 1
fi
if touch /work/.auto-cleanup-write-test 2>/dev/null; then
    echo "/work is unexpectedly writable" >&2
    rm -f /work/.auto-cleanup-write-test
    exit 1
fi
touch /tmp/auto-cleanup-posture-writable
printf '%s\n' '#!/bin/sh' 'exit 0' > /tmp/auto-cleanup-posture-exec
chmod +x /tmp/auto-cleanup-posture-exec
if /tmp/auto-cleanup-posture-exec 2>/dev/null; then
    echo "/tmp is executable; expected noexec" >&2
    exit 1
fi
rm -f /tmp/auto-cleanup-posture-writable /tmp/auto-cleanup-posture-exec

for entrypoint in "$REPO_DIR"/tests/*.sh; do
    case "$(basename "$entrypoint")" in
        02_container_posture.sh) continue ;;
    esac
    require_text "$entrypoint" "require-container.sh"
done

test "$(sed -n '1p' "$REPO_DIR/.dockerignore")" = "*"
reject_text "$REPO_DIR/.dockerignore" "!fixtures/**"
reject_text "$REPO_DIR/.dockerignore" "!scripts/**"
reject_text "$REPO_DIR/.dockerignore" "!tests/**"
require_text "$REPO_DIR/.dockerignore" "!fixtures/bin/vps-docker-clean"
require_text "$REPO_DIR/.dockerignore" "!scripts/install.sh"
require_text "$REPO_DIR/.dockerignore" "!tests/30_functionality.sh"
require_text "$REPO_DIR/.dockerignore" "!notes/001_containerized_test_strategy.txt"
for absent in .git .agents .codex; do
    if [ -e "$REPO_DIR/$absent" ]; then
        echo "ignored host state reached test image: $absent" >&2
        exit 1
    fi
done

workflow="$REPO_DIR/.github/workflows/container-tests.yml"
require_text "$workflow" "permissions:"
require_text "$workflow" "contents: read"
require_text "$workflow" "timeout-minutes:"
require_text "$workflow" "persist-credentials: false"
require_text "$workflow" "make test/posture"
require_text "$workflow" "make test/matrix"
require_text "$workflow" "make test/root-container"
require_text "$workflow" "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
reject_text "$workflow" "./tests/run.sh"
reject_text "$workflow" "./tests/30_functionality.sh"
reject_text "$workflow" "./tests/check-manifest.sh"
reject_text "$workflow" "/var/run/docker.sock"
reject_text "$workflow" "services:"
reject_text "$workflow" "secrets."
reject_text "$workflow" "GITHUB_TOKEN"
reject_text "$workflow" "docker login"
reject_text "$workflow" "sudo "

python3 - "$wrapper" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='auto-cleanup-launcher-', dir=os.environ['TMPDIR']) as scratch:
    root = Path(scratch)
    engine = root / 'engine'
    calls = root / 'calls'
    engine.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['MOCK_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[0] == 'build':
    if os.environ.get('MOCK_FAILURE') == 'build':
        sys.exit(17)
    builds = sum(json.loads(line)[0] == 'build' for line in pathlib.Path(os.environ['MOCK_CALLS']).read_text().splitlines())
    iid = 'malformed' if os.environ.get('MOCK_FAILURE') == 'id' else 'sha256:' + format(builds, '064x')
    pathlib.Path(args[args.index('--iidfile') + 1]).write_text(iid + '\\n')
    if os.environ.get('MOCK_FAILURE') == 'read':
        pathlib.Path(args[args.index('--iidfile') + 1]).unlink()
    # The shared tag now denotes another checkout's build.
    pathlib.Path(os.environ['MOCK_TAG']).write_text('sha256:' + 'b' * 64)
''')
    engine.chmod(0o755)
    env = dict(os.environ, DOCKER_CLI=str(engine), MOCK_CALLS=str(calls),
               MOCK_TAG=str(root / 'tag'), TMPDIR=str(root))
    for mode in ['test', 'test/matrix', 'test/root-container', 'test/posture', 'shell']:
        calls.write_text('')
        result = subprocess.run([sys.argv[1], mode], env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        argv = [json.loads(line) for line in calls.read_text().splitlines()]
        runs = [args for args in argv if args[0] == 'run']
        assert runs, argv
        assert all(not any(arg.startswith('auto-cleanup-test:') for arg in args) for args in runs), runs
        builds = 0
        for args in argv:
            if args[0] == 'build':
                builds += 1
                assert not Path(args[args.index('--iidfile') + 1]).exists()
            elif args[0] == 'run':
                assert 'sha256:' + format(builds, '064x') in args, args
    for failure in ['build', 'id', 'read']:
        calls.write_text('')
        result = subprocess.run([sys.argv[1], 'test'], env=dict(env, MOCK_FAILURE=failure),
                                text=True, capture_output=True)
        assert result.returncode != 0
        argv = [json.loads(line) for line in calls.read_text().splitlines()]
        assert not any(args[0] == 'run' for args in argv), argv
        assert not Path(argv[0][argv[0].index('--iidfile') + 1]).exists()
print('launcher image provenance ok')
PY

echo "container posture ok"
