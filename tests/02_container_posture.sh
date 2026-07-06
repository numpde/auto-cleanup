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

reject_text() {
    file=$1
    text=$2
    if grep -Fq -- "$text" "$file"; then
        echo "forbidden text in $file: $text" >&2
        exit 1
    fi
}

require_text "$wrapper" "--network none"
require_text "$wrapper" "--read-only"
require_text "$wrapper" "--cap-drop ALL"
require_text "$wrapper" "--security-opt no-new-privileges:true"
require_text "$wrapper" "--pull=never"
require_text "$wrapper" "--user 65532:65532"
require_text "$wrapper" "--pids-limit"
require_text "$wrapper" "--memory"
require_text "$wrapper" "--memory-swap"
require_text "$wrapper" "--tmpfs /tmp:rw,nosuid,nodev,noexec"
require_text "$wrapper" "--env AUTO_CLEANUP_TEST_CONTAINER=1"
require_text "$wrapper" "--env AUTO_CLEANUP_TEST_ROOT_CONTAINER=1"
require_text "$wrapper" "--cap-add CHOWN"
require_text "$wrapper" "--cap-add FOWNER"
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

for ignored in .git .agents .codex __pycache__ .pytest_cache tmp; do
    require_text "$REPO_DIR/.dockerignore" "$ignored"
done
for absent in .git .agents .codex; do
    if [ -e "$REPO_DIR/$absent" ]; then
        echo "ignored host state reached test image: $absent" >&2
        exit 1
    fi
done

workflow="$REPO_DIR/.github/workflows/container-tests.yml"
require_text "$workflow" "permissions:"
require_text "$workflow" "contents: read"
require_text "$workflow" "persist-credentials: false"
require_text "$workflow" "make test/posture"
require_text "$workflow" "make test/matrix"
require_text "$workflow" "make test/root-container"
require_text "$workflow" "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
reject_text "$workflow" "./tests/run.sh"
reject_text "$workflow" "./tests/30_functionality.sh"
reject_text "$workflow" "./tests/check-manifest.sh"
reject_text "$workflow" "/var/run/docker.sock"

echo "container posture ok"
