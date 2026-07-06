#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

echo "docs contract"

readme="$REPO_DIR/README.md"

grep -q '^make test$' "$readme"
if grep -Eq '^\./tests/(run|30_functionality|check-manifest)\.sh$' "$readme"; then
    echo "README exposes direct test script execution" >&2
    exit 1
fi
grep -q 'container-only; use `make test`' "$readme"

grep -q '| Docker logs | `local` driver, `10m` x `3`, compressed |' "$readme"
grep -q '| Docker build cache | prune older than `168h`, reserve `1GB` |' "$readme"
grep -q '| Docker containers/networks | prune unused older than `168h` |' "$readme"
grep -q '| Docker images | prune unused older than `720h` |' "$readme"
grep -q '| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |' "$readme"
grep -q '| btmp | rotate at `50M`, keep 1 rotated file |' "$readme"
grep -q '| APT cache | autoclean every 7 days, clean every 30 days |' "$readme"

grep -Eq '"log-driver"[[:space:]]*:[[:space:]]*"local"' "$REPO_DIR/fixtures/docker/daemon-log-policy.json"
grep -Eq '"max-size"[[:space:]]*:[[:space:]]*"10m"' "$REPO_DIR/fixtures/docker/daemon-log-policy.json"
grep -Eq '"max-file"[[:space:]]*:[[:space:]]*"3"' "$REPO_DIR/fixtures/docker/daemon-log-policy.json"
grep -q 'SystemMaxUse=300M' "$REPO_DIR/fixtures/journald/limits.conf"
grep -q 'SystemKeepFree=1G' "$REPO_DIR/fixtures/journald/limits.conf"
grep -q 'MaxRetentionSec=14day' "$REPO_DIR/fixtures/journald/limits.conf"
grep -q 'maxsize 50M' "$REPO_DIR/fixtures/logrotate/btmp"
grep -q 'rotate 1' "$REPO_DIR/fixtures/logrotate/btmp"
grep -q 'AutocleanInterval "7"' "$REPO_DIR/fixtures/apt/10periodic-cleanup"
grep -q 'CleanInterval "30"' "$REPO_DIR/fixtures/apt/10periodic-cleanup"

grep -q 'docker system prune --volumes' "$readme"
grep -q 'docker volume prune' "$readme"
grep -q 'direct deletion under `/var/lib/docker`' "$readme"
grep -q 'does not install jobs that run' "$readme"

for path in \
    scripts/install.sh \
    scripts/uninstall.sh \
    scripts/check.sh \
    fixtures/default/vps-docker-clean.example \
    fixtures/bin/vps-docker-clean
do
    if [ ! -e "$REPO_DIR/$path" ]; then
        echo "README-referenced path is missing: $path" >&2
        exit 1
    fi
done

echo "docs contract ok"
