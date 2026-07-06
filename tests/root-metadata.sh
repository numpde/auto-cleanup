#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

echo "root metadata"

if [ "${AUTO_CLEANUP_TEST_ROOT_CONTAINER:-}" != "1" ]; then
    echo "root metadata tests must run through: make test/root-container" >&2
    exit 2
fi
if [ "$(id -u)" != "0" ]; then
    echo "root metadata lane must run as uid 0" >&2
    exit 1
fi
if [ -e /var/run/docker.sock ]; then
    echo "Docker socket is visible in root metadata lane" >&2
    exit 1
fi
if awk '$2 == "00000000" && $1 != "lo" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/route; then
    echo "default network route is present in root metadata lane" >&2
    exit 1
fi
if touch /work/.auto-cleanup-root-write-test 2>/dev/null; then
    echo "/work is unexpectedly writable in root metadata lane" >&2
    rm -f /work/.auto-cleanup-root-write-test
    exit 1
fi
printf '%s\n' '#!/bin/sh' 'exit 0' > /tmp/auto-cleanup-root-posture-exec
chmod +x /tmp/auto-cleanup-root-posture-exec
if /tmp/auto-cleanup-root-posture-exec 2>/dev/null; then
    echo "/tmp is executable in root metadata lane; expected noexec" >&2
    exit 1
fi
rm -f /tmp/auto-cleanup-root-posture-exec

ROOT=$(mktemp -d "${TMPDIR:-/run/auto-cleanup-test}/auto-cleanup-root-meta.XXXXXX")
cleanup() {
    rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT/etc/docker"
cat > "$ROOT/etc/docker/daemon.json" <<'EOF'
{"debug": false}
EOF
chmod 0644 "$ROOT/etc/docker/daemon.json"
chown 123:123 "$ROOT/etc/docker/daemon.json"

"$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$ROOT/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" >/dev/null

mode=$(stat -c '%a' "$ROOT/etc/docker/daemon.json")
owner=$(stat -c '%u:%g' "$ROOT/etc/docker/daemon.json")
test "$mode" = "644"
test "$owner" = "123:123"

backup=$(find "$ROOT/etc/docker" -name 'daemon.json.auto-cleanup.bak.*' -print | head -n 1)
test -n "$backup"
backup_mode=$(stat -c '%a' "$backup")
backup_owner=$(stat -c '%u:%g' "$backup")
test "$backup_mode" = "644"
test "$backup_owner" = "123:123"

echo "root metadata ok"
