#!/bin/sh
# Exercise real installer orchestration with inert file and service dependencies.
# This proves progress ordering and failure reporting, not live Docker recovery.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-progress.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/repo" "$scratch/bin" "$scratch/repo/lib"
cp -R "$REPO_DIR/scripts" "$REPO_DIR/fixtures" "$scratch/repo/"
cmp "$REPO_DIR/scripts/install.sh" "$scratch/repo/scripts/install.sh"

# Default-path file writes are inert; the container's /etc stays read-only.
cat > "$scratch/bin/install" <<'SH'
#!/bin/sh
set -eu
case "$1:$2:$#" in
    -d:-m:4|-m:0755:4|-m:0644:4) exit 0 ;;
    *) echo "unexpected install arguments: $*" >&2; exit 2 ;;
esac
SH
cat > "$scratch/repo/lib/merge-docker-daemon.py" <<'SH'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        --daemon-json|--policy-json|--cache-gib|--output-json) shift 2 ;;
        --dry-run) shift ;;
        *) echo "unexpected merger argument: $1" >&2; exit 2 ;;
    esac
done
SH
cat > "$scratch/repo/lib/apt-cleanup-policy.py" <<'PY'
import sys
assert sys.argv[1:3] == ['--apt-dir', '/etc/apt']
assert len(sys.argv) == 5 and sys.argv[3] == '--candidate-policy'
print('install')
PY
cat > "$scratch/bin/systemctl" <<'SH'
#!/bin/sh
set -eu
# Inspect output at subprocess entry: a final transcript alone cannot prove timing.
grep -Fxq "Running: systemctl $*" "$PROGRESS_OUTPUT"
if grep -Fxq "Completed: systemctl $*" "$PROGRESS_OUTPUT"; then
    echo 'service completion was announced before the call returned' >&2; exit 2
fi
echo "fake service entry: $*"
case "$*" in
    daemon-reload|'enable --now vps-docker-clean.timer') ;;
    'restart systemd-journald')
        if [ "$PROGRESS_MODE" = journald-fails ]; then exit 43; fi
        ;;
    'restart docker')
        grep -q 'sudo journalctl -fu docker.service' "$PROGRESS_OUTPUT"
        if [ "$PROGRESS_MODE" = both-fail ] ||
            { [ "$PROGRESS_MODE" = first-fails ] && [ ! -e "$PROGRESS_RETRIED" ]; }; then
            touch "$PROGRESS_RETRIED"
            echo 'injected Docker restart failure' >&2
            exit 42
        fi
        ;;
    *) echo "unexpected systemctl arguments: $*" >&2; exit 2 ;;
esac
SH
chmod 0755 "$scratch/bin/install" "$scratch/bin/systemctl" "$scratch/repo/lib/merge-docker-daemon.py"
ln -s "$REPO_DIR/tests/fixtures/fake-dockerd.sh" "$scratch/bin/dockerd"

# The absent-daemon rollback path is sufficient here; no default-path file is created.
test ! -e /etc/docker/daemon.json
for mode in success first-fails both-fail journald-fails; do
    status=0
    output=$scratch/$mode.out
    PROGRESS_MODE=$mode PROGRESS_OUTPUT=$output PROGRESS_RETRIED=$scratch/$mode.retried \
        FAKE_DOCKERD_LOG=$scratch/dockerd.log PATH="$scratch/bin:$PATH" \
        "$scratch/repo/scripts/install.sh" --restart-docker --skip-btmp-logrotate --skip-apt-periodic \
        >"$output" 2>&1 || status=$?
    case "$mode" in
        success)
            test "$status" -eq 0
            grep -Fxq 'Completed: systemctl restart docker' "$output"
            grep -Fxq 'Installation complete.' "$output"
            ;;
        first-fails|both-fail)
            test "$status" -eq 1
            grep -q 'injected Docker restart failure' "$output"
            grep -q 'Failed: systemctl restart docker (exit 42)' "$output"
            grep -q 'other installed files and service changes remain' "$output"
            grep -q 'Retrying Docker restart with the previous daemon configuration' "$output"
            if [ "$mode" = first-fails ]; then
                grep -q 'Docker recovery restart completed, but installation failed' "$output"
            else
                grep -q 'Docker recovery restart also failed' "$output"
            fi
            ;;
        journald-fails)
            test "$status" -eq 43
            grep -q 'Failed: systemctl restart systemd-journald (exit 43)' "$output"
            ;;
    esac
    printf '%s\n' 'daemon-reload' 'enable --now vps-docker-clean.timer' \
        'restart systemd-journald' > "$scratch/expected-calls"
    if [ "$mode" != journald-fails ]; then
        echo 'restart docker' >> "$scratch/expected-calls"
    fi
    if [ "$mode" = first-fails ] || [ "$mode" = both-fail ]; then
        echo 'restart docker' >> "$scratch/expected-calls"
    fi
    sed -n 's/^fake service entry: //p' "$output" > "$scratch/actual-calls"
    cmp "$scratch/expected-calls" "$scratch/actual-calls"
    if [ "$status" -ne 0 ] && grep -Fxq 'Installation complete.' "$output"; then
        echo 'failed installation reported completion' >&2; exit 1
    fi
done

PROGRESS_OUTPUT=$scratch/dry.out PATH="$scratch/bin:$PATH" \
    "$scratch/repo/scripts/install.sh" --dry-run --skip-docker-config >"$scratch/dry.out" 2>&1
grep -q 'would run: systemctl daemon-reload' "$scratch/dry.out"
if grep -Eq '^(Running:|Completed:|Installation complete\.)' "$scratch/dry.out"; then
    echo 'dry-run reported a real operation' >&2; exit 1
fi
echo 'install progress ok'
