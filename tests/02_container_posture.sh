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

echo "container posture ok"
