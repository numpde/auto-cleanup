#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-test.XXXXXX")
MERGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-merge.XXXXXX")
FAKE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-fake-docker.XXXXXX")

for test_root in "$ROOT" "$MERGE_ROOT" "$FAKE_ROOT"; do
    case "$test_root" in
        ""|"/"|"/tmp")
            echo "unsafe test root calculation: $test_root" >&2
            exit 1
            ;;
    esac
    case "$test_root" in
        */auto-cleanup-*) ;;
        *)
            echo "unexpected test root name: $test_root" >&2
            exit 1
            ;;
    esac
done

cleanup() {
    rm -rf "$ROOT"
    rm -rf "$MERGE_ROOT"
    rm -rf "$FAKE_ROOT"
}
trap cleanup EXIT INT TERM
cleanup

for script in install check uninstall; do
    "$REPO_DIR/scripts/$script.sh" --help >/dev/null
done
test -f "$REPO_DIR/scripts/lib/common.sh"

PARTIAL_REPO="$MERGE_ROOT/partial-repo"
mkdir -p "$PARTIAL_REPO/scripts"
for script in install check uninstall; do
    cp "$REPO_DIR/scripts/$script.sh" "$PARTIAL_REPO/scripts/$script.sh"
    case "$script" in
        check) partial_args=--strict ;;
        *) partial_args=--dry-run ;;
    esac
    if "$PARTIAL_REPO/scripts/$script.sh" "$partial_args" >/dev/null 2>"$MERGE_ROOT/partial-repo.err"; then
        echo "partial checkout $script unexpectedly succeeded" >&2
        exit 1
    fi
    grep -q 'missing support file:' "$MERGE_ROOT/partial-repo.err"
done
mkdir -p "$PARTIAL_REPO/scripts/lib"
cp "$REPO_DIR/scripts/lib/common.sh" "$PARTIAL_REPO/scripts/lib/common.sh"
if "$PARTIAL_REPO/scripts/install.sh" --dry-run --skip-docker-config >/dev/null 2>"$MERGE_ROOT/partial-repo.err"; then
    echo "partial checkout install with missing fixtures unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'missing source file:' "$MERGE_ROOT/partial-repo.err"
mkdir -p "$PARTIAL_REPO/fixtures"
for fixture_dir in bin systemd journald logrotate apt docker; do
    cp -R "$REPO_DIR/fixtures/$fixture_dir" "$PARTIAL_REPO/fixtures/$fixture_dir"
done
if "$PARTIAL_REPO/scripts/install.sh" --dry-run >/dev/null 2>"$MERGE_ROOT/partial-repo.err"; then
    echo "partial checkout install with missing Docker helper unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'missing source file:' "$MERGE_ROOT/partial-repo.err"

# Default staged install, idempotence, and core policy checks.
"$REPO_DIR/scripts/install.sh" --root "$ROOT" >/dev/null
"$REPO_DIR/tests/check-manifest.sh" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$ROOT" --strict >/dev/null
backup_count_before=$(find "$ROOT/etc/docker" -name 'daemon.json.auto-cleanup.bak.*' | wc -l)
"$REPO_DIR/scripts/install.sh" --root "$ROOT" >/dev/null
backup_count_after=$(find "$ROOT/etc/docker" -name 'daemon.json.auto-cleanup.bak.*' | wc -l)
test "$backup_count_before" = "$backup_count_after"
mkdir -p "$FAKE_ROOT/no-python-bin"
for cmd in grep dirname df systemctl docker mktemp sed install rm; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ln -s "$(command -v "$cmd")" "$FAKE_ROOT/no-python-bin/$cmd"
    fi
done
if PATH="$FAKE_ROOT/no-python-bin" "$REPO_DIR/scripts/check.sh" --root "$ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted Docker policy without python3" >&2
    exit 1
fi
if PATH="$FAKE_ROOT/no-python-bin" "$REPO_DIR/scripts/install.sh" --root "$MERGE_ROOT/no-python-install" >/dev/null 2>&1; then
    echo "install unexpectedly accepted Docker config without python3" >&2
    exit 1
fi
PATH="$FAKE_ROOT/no-python-bin" "$REPO_DIR/scripts/install.sh" \
    --root "$MERGE_ROOT/no-python-skip" \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null

if command -v logrotate >/dev/null 2>&1; then
    LOGROTATE_STATE="$ROOT/logrotate-state"
    logrotate -d -s "$LOGROTATE_STATE" "$REPO_DIR/fixtures/logrotate/btmp" >/dev/null 2>&1
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    cat > "$ROOT/etc/systemd/system/sysinit.target" <<'EOF'
[Unit]
Description=Minimal test sysinit target
EOF
    cat > "$ROOT/etc/systemd/system/timers.target" <<'EOF'
[Unit]
Description=Minimal test timers target
EOF
    systemd-analyze --root="$ROOT" verify \
        /etc/systemd/system/vps-docker-clean.service \
        /etc/systemd/system/vps-docker-clean.timer >/dev/null 2>&1 || {
            echo "systemd unit verification failed" >&2
            exit 1
        }
fi

test -x "$ROOT/usr/local/sbin/vps-docker-clean"
test -f "$ROOT/etc/systemd/system/vps-docker-clean.service"
grep -q 'ConditionFileIsExecutable=/usr/local/sbin/vps-docker-clean' "$ROOT/etc/systemd/system/vps-docker-clean.service"
grep -q 'EnvironmentFile=-/etc/default/vps-docker-clean' "$ROOT/etc/systemd/system/vps-docker-clean.service"
grep -q 'IOSchedulingClass=idle' "$ROOT/etc/systemd/system/vps-docker-clean.service"
test -f "$ROOT/etc/systemd/system/vps-docker-clean.timer"
grep -q 'AccuracySec=1h' "$ROOT/etc/systemd/system/vps-docker-clean.timer"
test -f "$ROOT/etc/systemd/journald.conf.d/auto-cleanup-limits.conf"
test -f "$ROOT/etc/logrotate.d/auto-cleanup-btmp"
test -f "$ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
test -f "$ROOT/etc/docker/daemon.json"
mode=$(stat -c '%a' "$ROOT/etc/docker/daemon.json")
test "$mode" = "644"
if grep -Eq 'volume prune|--volumes' "$ROOT/usr/local/sbin/vps-docker-clean"; then
    echo "cleanup script must not prune Docker volumes" >&2
    exit 1
fi
grep -q 'Docker daemon not reachable; skipping cleanup.' "$ROOT/usr/local/sbin/vps-docker-clean"

python3 - "$ROOT/etc/docker/daemon.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["log-driver"] == "local"
assert data["log-opts"]["max-size"] == "10m"
assert data["log-opts"]["max-file"] == "3"
assert data["log-opts"]["compress"] == "true"
PY

"$REPO_DIR/scripts/uninstall.sh" --root "$ROOT" >/dev/null

test ! -e "$ROOT/usr/local/sbin/vps-docker-clean"
test ! -e "$ROOT/etc/systemd/system/vps-docker-clean.service"
test ! -e "$ROOT/etc/systemd/system/vps-docker-clean.timer"

"$REPO_DIR/scripts/install.sh" --root "$ROOT" >/dev/null
if "$REPO_DIR/scripts/uninstall.sh" \
    --root "$ROOT" \
    --restore-docker-backup "$ROOT/backup/missing-daemon.json" >/dev/null 2>&1; then
    echo "uninstall with missing Docker backup unexpectedly succeeded" >&2
    exit 1
fi
test -x "$ROOT/usr/local/sbin/vps-docker-clean"
test -f "$ROOT/etc/systemd/system/vps-docker-clean.service"
test -f "$ROOT/etc/systemd/system/vps-docker-clean.timer"

mkdir -p "$ROOT/backup"
cat > "$ROOT/backup/daemon.json" <<'EOF'
{"log-driver":"json-file"}
EOF
chmod 0600 "$ROOT/backup/daemon.json"
ln -s "$ROOT/backup/daemon.json" "$ROOT/backup/daemon-link.json"
if "$REPO_DIR/scripts/uninstall.sh" \
    --root "$ROOT" \
    --restore-docker-backup "$ROOT/backup/daemon-link.json" >/dev/null 2>&1; then
    echo "uninstall with symlink Docker backup unexpectedly succeeded" >&2
    exit 1
fi
rm -f "$ROOT/etc/docker/daemon.json"
ln -s "$ROOT/backup/daemon-target.json" "$ROOT/etc/docker/daemon.json"
if "$REPO_DIR/scripts/uninstall.sh" \
    --root "$ROOT" \
    --restore-docker-backup "$ROOT/backup/daemon.json" >/dev/null 2>&1; then
    echo "uninstall with symlink Docker restore destination unexpectedly succeeded" >&2
    exit 1
fi
rm -f "$ROOT/etc/docker/daemon.json"
mkdir -p "$ROOT/etc/docker/daemon.json"
if "$REPO_DIR/scripts/uninstall.sh" \
    --root "$ROOT" \
    --restore-docker-backup "$ROOT/backup/daemon.json" >/dev/null 2>&1; then
    echo "uninstall with directory Docker restore destination unexpectedly succeeded" >&2
    exit 1
fi
rm -rf "$ROOT/etc/docker/daemon.json"
"$REPO_DIR/scripts/uninstall.sh" \
    --root "$ROOT" \
    --restore-docker-backup "$ROOT/backup/daemon.json" >/dev/null
grep -q 'json-file' "$ROOT/etc/docker/daemon.json"
mode=$(stat -c '%a' "$ROOT/etc/docker/daemon.json")
test "$mode" = "600"
if "$REPO_DIR/scripts/check.sh" --root "$ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted non-policy Docker daemon config" >&2
    exit 1
fi

# Docker daemon merge behavior and install preflight failures.
mkdir -p "$MERGE_ROOT/etc/docker"
cat > "$MERGE_ROOT/etc/docker/daemon.json" <<'EOF'
{
  "data-root": "/srv/docker",
  "features": {
    "buildkit": true
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1m"
  }
}
EOF

"$REPO_DIR/scripts/install.sh" --root "$MERGE_ROOT" >/dev/null
"$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" >/dev/null

python3 - "$MERGE_ROOT/etc/docker/daemon.json" <<'PY'
import glob
import json
import os
import sys

daemon_path = sys.argv[1]
with open(daemon_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["data-root"] == "/srv/docker"
assert data["features"]["buildkit"] is True
assert data["log-driver"] == "local"
assert data["log-opts"]["max-size"] == "10m"
assert data["log-opts"]["max-file"] == "3"
backups = glob.glob(daemon_path + ".auto-cleanup.bak.*")
assert backups
with open(backups[0], "r", encoding="utf-8") as handle:
    backup_data = json.load(handle)
assert backup_data["log-driver"] == "json-file"
assert backup_data["log-opts"]["max-size"] == "1m"
daemon_stat = os.stat(daemon_path)
backup_stat = os.stat(backups[0])
assert (backup_stat.st_uid, backup_stat.st_gid) == (daemon_stat.st_uid, daemon_stat.st_gid)
PY

expect_fail() {
    label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "$label unexpectedly succeeded" >&2
        exit 1
    fi
}

for script in install check uninstall; do
    expect_fail "$script relative --root" "$REPO_DIR/scripts/$script.sh" --root relative-root
    expect_fail "$script --root /" "$REPO_DIR/scripts/$script.sh" --root /
    expect_fail "$script double-leading-slash --root" "$REPO_DIR/scripts/$script.sh" --root //tmp/auto-cleanup
    expect_fail "$script --root ////" "$REPO_DIR/scripts/$script.sh" --root ////
    expect_fail "$script space-containing --root" "$REPO_DIR/scripts/$script.sh" --root "/tmp/auto cleanup space"
    expect_fail "$script backslash-containing --root" "$REPO_DIR/scripts/$script.sh" --root "/tmp/auto\\cleanup"
    expect_fail "$script --prefix /" "$REPO_DIR/scripts/$script.sh" --prefix /
    expect_fail "$script ampersand-containing --prefix" "$REPO_DIR/scripts/$script.sh" --prefix "/opt/auto&cleanup"
    expect_fail "$script percent-containing --prefix" "$REPO_DIR/scripts/$script.sh" --prefix "/opt/auto%cleanup"
    expect_fail "$script dollar-containing --prefix" "$REPO_DIR/scripts/$script.sh" --prefix '/opt/auto$cleanup'
    expect_fail "$script quote-containing --prefix" "$REPO_DIR/scripts/$script.sh" --prefix '/opt/auto"cleanup'
    expect_fail "$script relative --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir relative-etc
    expect_fail "$script pipe-containing --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir "/etc/auto|cleanup"
    expect_fail "$script hash-containing --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir "/etc/auto#cleanup"
    expect_fail "$script semicolon-containing --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir "/etc/auto;cleanup"
    expect_fail "$script apostrophe-containing --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir "/etc/auto'cleanup"
    expect_fail "$script backtick-containing --etc-dir" "$REPO_DIR/scripts/$script.sh" --etc-dir '/etc/auto`cleanup'
done
expect_fail "uninstall relative Docker backup" \
    "$REPO_DIR/scripts/uninstall.sh" --restore-docker-backup daemon.json.auto-cleanup.bak
expect_fail "uninstall double-leading-slash Docker backup" \
    "$REPO_DIR/scripts/uninstall.sh" --restore-docker-backup //tmp/daemon.json.auto-cleanup.bak
expect_fail "uninstall shell-metachar Docker backup" \
    "$REPO_DIR/scripts/uninstall.sh" --restore-docker-backup '/tmp/daemon$backup.json'

# Dry-run and custom path behavior.
custom_etc_install_output=$("$REPO_DIR/scripts/install.sh" \
    --dry-run \
    --etc-dir /custom/etc \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic)
if printf '%s\n' "$custom_etc_install_output" | grep -q 'would run: systemctl'; then
    echo "install unexpectedly ran systemctl actions with custom --etc-dir" >&2
    exit 1
fi

custom_etc_uninstall_output=$("$REPO_DIR/scripts/uninstall.sh" \
    --dry-run \
    --etc-dir /custom/etc)
if printf '%s\n' "$custom_etc_uninstall_output" | grep -q 'would run: systemctl'; then
    echo "uninstall unexpectedly ran systemctl actions with custom --etc-dir" >&2
    exit 1
fi
default_etc_install_output=$("$REPO_DIR/scripts/install.sh" \
    --dry-run \
    --etc-dir /etc/ \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic)
printf '%s\n' "$default_etc_install_output" | grep -q 'would run: systemctl daemon-reload'
no_service_install_output=$("$REPO_DIR/scripts/install.sh" \
    --dry-run \
    --no-service-actions \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic)
if printf '%s\n' "$no_service_install_output" | grep -q 'would run: systemctl'; then
    echo "install unexpectedly ran systemctl actions with --no-service-actions" >&2
    exit 1
fi
no_service_uninstall_output=$("$REPO_DIR/scripts/uninstall.sh" \
    --dry-run \
    --no-service-actions)
if printf '%s\n' "$no_service_uninstall_output" | grep -q 'would run: systemctl'; then
    echo "uninstall unexpectedly ran systemctl actions with --no-service-actions" >&2
    exit 1
fi
no_enable_timer_output=$("$REPO_DIR/scripts/install.sh" \
    --dry-run \
    --no-enable-timer \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic)
printf '%s\n' "$no_enable_timer_output" | grep -q 'would run: systemctl daemon-reload'
if printf '%s\n' "$no_enable_timer_output" | grep -q 'enable --now vps-docker-clean.timer'; then
    echo "install unexpectedly enabled timer with --no-enable-timer" >&2
    exit 1
fi

DRY_ROOT="$MERGE_ROOT/dry-run"
dry_run_output=$("$REPO_DIR/scripts/install.sh" --root "$DRY_ROOT" --dry-run)
printf '%s\n' "$dry_run_output" | grep -q 'would install:'
test "$(printf '%s\n' "$dry_run_output" | tail -n 1)" = "Dry-run complete; no files were installed."
if printf '%s\n' "$dry_run_output" | grep -Eq '/tmp/tmp|would run: install'; then
    echo "dry-run install output exposed low-level install details" >&2
    exit 1
fi
test ! -e "$DRY_ROOT/usr/local/sbin/vps-docker-clean"

dry_uninstall_output=$("$REPO_DIR/scripts/uninstall.sh" --dry-run --no-service-actions)
test "$(printf '%s\n' "$dry_uninstall_output" | tail -n 1)" = "Dry-run complete; no files were removed."

mkdir -p "$MERGE_ROOT/bad/etc/docker"
cat > "$MERGE_ROOT/bad/etc/docker/daemon.json" <<'EOF'
{
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/bad/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
    --dry-run >/dev/null 2>&1; then
    echo "invalid daemon JSON unexpectedly succeeded" >&2
    exit 1
fi
if "$REPO_DIR/scripts/install.sh" --root "$MERGE_ROOT/bad" >/dev/null 2>&1; then
    echo "install with invalid daemon JSON unexpectedly succeeded" >&2
    exit 1
fi
test ! -e "$MERGE_ROOT/bad/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/install.sh" --root "$MERGE_ROOT/bad" --dry-run >/dev/null 2>&1; then
    echo "dry-run install with invalid daemon JSON unexpectedly succeeded" >&2
    exit 1
fi
mkdir -p "$MERGE_ROOT/bad-utf8/etc/docker"
printf '\\377' > "$MERGE_ROOT/bad-utf8/etc/docker/daemon.json"
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/bad-utf8/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
    --dry-run >/dev/null 2>&1; then
    echo "invalid UTF-8 daemon JSON unexpectedly succeeded" >&2
    exit 1
fi
mkdir -p "$MERGE_ROOT/dir-daemon/etc/docker/daemon.json"
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/dir-daemon/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
    --dry-run >/dev/null 2>&1; then
    echo "directory Docker daemon path unexpectedly succeeded" >&2
    exit 1
fi
mkdir -p "$MERGE_ROOT/dir-policy"
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/dir-policy" \
    --dry-run >/dev/null 2>&1; then
    echo "directory Docker policy path unexpectedly succeeded" >&2
    exit 1
fi

mkdir -p "$MERGE_ROOT/symlink-install/usr/local/sbin"
cat > "$MERGE_ROOT/symlink-install-target" <<'EOF'
do not overwrite
EOF
ln -s "$MERGE_ROOT/symlink-install-target" "$MERGE_ROOT/symlink-install/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/install.sh" \
    --root "$MERGE_ROOT/symlink-install" \
    --skip-docker-config >/dev/null 2>&1; then
    echo "install unexpectedly replaced a symlink destination" >&2
    exit 1
fi
grep -q 'do not overwrite' "$MERGE_ROOT/symlink-install-target"

mkdir -p "$MERGE_ROOT/directory-install/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/install.sh" \
    --root "$MERGE_ROOT/directory-install" \
    --skip-docker-config >/dev/null 2>&1; then
    echo "install unexpectedly accepted a directory destination" >&2
    exit 1
fi

cat > "$MERGE_ROOT/bad-policy.json" <<'EOF'
{"log-opts":{"max-file":3}}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy.json" \
    --dry-run >/dev/null 2>&1; then
    echo "non-string Docker log option unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-driver.json" <<'EOF'
{"log-driver":3}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-driver.json" \
    --dry-run >/dev/null 2>&1; then
    echo "non-string Docker log driver unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-driver-value.json" <<'EOF'
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3","compress":"true"}}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-driver-value.json" \
    --dry-run >/dev/null 2>&1; then
    echo "wrong Docker log driver value unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-missing-driver.json" <<'EOF'
{"log-opts":{"max-file":"3"}}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-missing-driver.json" \
    --dry-run >/dev/null 2>&1; then
    echo "missing Docker log driver unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-missing-opts.json" <<'EOF'
{"log-driver":"local"}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-missing-opts.json" \
    --dry-run >/dev/null 2>&1; then
    echo "missing Docker log opts unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-opt-value.json" <<'EOF'
{"log-driver":"local","log-opts":{"max-size":"100m","max-file":"3","compress":"true"}}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-opt-value.json" \
    --dry-run >/dev/null 2>&1; then
    echo "wrong Docker log option value unexpectedly succeeded" >&2
    exit 1
fi
cat > "$MERGE_ROOT/bad-policy-extra-opt.json" <<'EOF'
{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3","compress":"true","tag":"{{.Name}}"}}
EOF
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/etc/docker/daemon.json" \
    --policy-json "$MERGE_ROOT/bad-policy-extra-opt.json" \
    --dry-run >/dev/null 2>&1; then
    echo "extra Docker log option unexpectedly succeeded" >&2
    exit 1
fi
mkdir -p "$MERGE_ROOT/symlink/etc/docker"
cat > "$MERGE_ROOT/symlink-target.json" <<'EOF'
{"debug": true}
EOF
ln -s "$MERGE_ROOT/symlink-target.json" "$MERGE_ROOT/symlink/etc/docker/daemon.json"
if "$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$MERGE_ROOT/symlink/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
    --dry-run >/dev/null 2>&1; then
    echo "symlink Docker daemon path unexpectedly succeeded" >&2
    exit 1
fi

mkdir -p "$ROOT/etc/logrotate.d"
cat > "$ROOT/etc/logrotate.d/distro-btmp" <<'EOF'
/var/log/btmp {
    monthly
}
EOF
cat > "$ROOT/etc/logrotate.d/unrelated-size-cap" <<'EOF'
/var/log/other.log {
    maxsize 50M
}
EOF
rm -f "$ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/install.sh" --root "$ROOT" --skip-docker-config >/dev/null
test -e "$ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$ROOT" --skip-docker-config --strict >/dev/null
cat > "$ROOT/etc/logrotate.d/distro-btmp" <<'EOF'
/var/log/btmp {
    monthly
    maxsize 50M
}
EOF

BTMP_COMMENTED_ROOT="$MERGE_ROOT/btmp-commented"
mkdir -p "$BTMP_COMMENTED_ROOT/etc/logrotate.d"
cat > "$BTMP_COMMENTED_ROOT/etc/logrotate.d/example" <<'EOF'
# /var/log/btmp {
#     maxsize 50M
# }
EOF
"$REPO_DIR/scripts/install.sh" --root "$BTMP_COMMENTED_ROOT" --skip-docker-config >/dev/null
test -e "$BTMP_COMMENTED_ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$BTMP_COMMENTED_ROOT" --skip-docker-config --strict >/dev/null

BTMP_SPLIT_STANZA_ROOT="$MERGE_ROOT/btmp-split-stanza"
mkdir -p "$BTMP_SPLIT_STANZA_ROOT/etc/logrotate.d"
cat > "$BTMP_SPLIT_STANZA_ROOT/etc/logrotate.d/distro-btmp" <<'EOF'
/var/log/btmp {
    monthly
}

/var/log/other.log {
    maxsize 50M
}
EOF
"$REPO_DIR/scripts/install.sh" --root "$BTMP_SPLIT_STANZA_ROOT" --skip-docker-config >/dev/null
test -e "$BTMP_SPLIT_STANZA_ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$BTMP_SPLIT_STANZA_ROOT" --skip-docker-config --strict >/dev/null

BTMP_COMBINED_ROOT="$MERGE_ROOT/btmp-combined"
mkdir -p "$BTMP_COMBINED_ROOT/etc/logrotate.d"
cat > "$BTMP_COMBINED_ROOT/etc/logrotate.d/distro-btmp" <<'EOF'
/var/log/wtmp /var/log/btmp {
    monthly
    maxsize 50M
}
EOF
"$REPO_DIR/scripts/install.sh" --root "$BTMP_COMBINED_ROOT" --skip-docker-config >/dev/null
test ! -e "$BTMP_COMBINED_ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$BTMP_COMBINED_ROOT" --skip-docker-config --strict >/dev/null

BTMP_EOL_ROOT="$MERGE_ROOT/btmp-eol"
mkdir -p "$BTMP_EOL_ROOT/etc/logrotate.d"
cat > "$BTMP_EOL_ROOT/etc/logrotate.d/distro-btmp" <<'EOF'
/var/log/btmp
{
    maxsize 50M
}
EOF
"$REPO_DIR/scripts/install.sh" --root "$BTMP_EOL_ROOT" --skip-docker-config >/dev/null
test ! -e "$BTMP_EOL_ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$BTMP_EOL_ROOT" --skip-docker-config --strict >/dev/null

BTMP_SUFFIX_ROOT="$MERGE_ROOT/btmp-suffix"
mkdir -p "$BTMP_SUFFIX_ROOT/etc/logrotate.d"
cat > "$BTMP_SUFFIX_ROOT/etc/logrotate.d/not-btmp" <<'EOF'
/var/log/btmp-old {
    maxsize 50M
}
EOF
"$REPO_DIR/scripts/install.sh" --root "$BTMP_SUFFIX_ROOT" --skip-docker-config >/dev/null
test -e "$BTMP_SUFFIX_ROOT/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/check.sh" --root "$BTMP_SUFFIX_ROOT" --skip-docker-config --strict >/dev/null

mkdir -p "$ROOT/etc/apt/apt.conf.d"
cat > "$ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
APT::Periodic::AutocleanInterval "7";
EOF
rm -f "$ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/install.sh" --root "$ROOT" --skip-docker-config --skip-btmp-logrotate >/dev/null
test ! -e "$ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$ROOT" --skip-docker-config --strict >/dev/null

APT_UPDATE_ONLY_ROOT="$MERGE_ROOT/apt-update-only"
mkdir -p "$APT_UPDATE_ONLY_ROOT/etc/apt/apt.conf.d"
cat > "$APT_UPDATE_ONLY_ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
EOF
"$REPO_DIR/scripts/install.sh" --root "$APT_UPDATE_ONLY_ROOT" --skip-docker-config >/dev/null
test -e "$APT_UPDATE_ONLY_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$APT_UPDATE_ONLY_ROOT" --skip-docker-config --strict >/dev/null

APT_DISABLED_ROOT="$MERGE_ROOT/apt-disabled"
mkdir -p "$APT_DISABLED_ROOT/etc/apt/apt.conf.d"
cat > "$APT_DISABLED_ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
APT::Periodic::AutocleanInterval "0";
EOF
"$REPO_DIR/scripts/install.sh" --root "$APT_DISABLED_ROOT" --skip-docker-config >/dev/null
test -e "$APT_DISABLED_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$APT_DISABLED_ROOT" --skip-docker-config --strict >/dev/null

APT_ALWAYS_ROOT="$MERGE_ROOT/apt-always"
mkdir -p "$APT_ALWAYS_ROOT/etc/apt/apt.conf.d"
cat > "$APT_ALWAYS_ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
APT::Periodic::AutocleanInterval "always";
EOF
"$REPO_DIR/scripts/install.sh" --root "$APT_ALWAYS_ROOT" --skip-docker-config >/dev/null
test ! -e "$APT_ALWAYS_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$APT_ALWAYS_ROOT" --skip-docker-config --strict >/dev/null

APT_SPACED_SEMI_ROOT="$MERGE_ROOT/apt-spaced-semi"
mkdir -p "$APT_SPACED_SEMI_ROOT/etc/apt/apt.conf.d"
cat > "$APT_SPACED_SEMI_ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
APT::Periodic::CleanInterval "30" ;
EOF
"$REPO_DIR/scripts/install.sh" --root "$APT_SPACED_SEMI_ROOT" --skip-docker-config >/dev/null
test ! -e "$APT_SPACED_SEMI_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$APT_SPACED_SEMI_ROOT" --skip-docker-config --strict >/dev/null

APT_COMMENTED_ROOT="$MERGE_ROOT/apt-commented"
mkdir -p "$APT_COMMENTED_ROOT/etc/apt/apt.conf.d"
cat > "$APT_COMMENTED_ROOT/etc/apt/apt.conf.d/10periodic" <<'EOF'
// APT::Periodic::AutocleanInterval "7";
# APT::Periodic::CleanInterval "30";
EOF
"$REPO_DIR/scripts/install.sh" --root "$APT_COMMENTED_ROOT" --skip-docker-config >/dev/null
test -e "$APT_COMMENTED_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$APT_COMMENTED_ROOT" --skip-docker-config --strict >/dev/null

PARTIAL_ROOT="$MERGE_ROOT/partial"
"$REPO_DIR/scripts/install.sh" \
    --root "$PARTIAL_ROOT" \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null
"$REPO_DIR/scripts/check.sh" \
    --root "$PARTIAL_ROOT" \
    --skip-docker-config \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic \
    --strict >/dev/null
test ! -e "$PARTIAL_ROOT/etc/systemd/journald.conf.d/auto-cleanup-limits.conf"

CUSTOM_ROOT="$MERGE_ROOT/custom"
"$REPO_DIR/scripts/install.sh" \
    --root "$CUSTOM_ROOT" \
    --prefix /opt/auto-cleanup \
    --etc-dir /custom/etc \
    --skip-docker-config \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null
"$REPO_DIR/scripts/check.sh" \
    --root "$CUSTOM_ROOT" \
    --prefix /opt/auto-cleanup \
    --etc-dir /custom/etc \
    --skip-docker-config \
    --skip-btmp-logrotate \
    --skip-apt-periodic \
    --strict >/dev/null
grep -q 'ExecStart=/opt/auto-cleanup/sbin/vps-docker-clean' "$CUSTOM_ROOT/custom/etc/systemd/system/vps-docker-clean.service"
grep -q 'EnvironmentFile=-/custom/etc/default/vps-docker-clean' "$CUSTOM_ROOT/custom/etc/systemd/system/vps-docker-clean.service"

TRAILING_ROOT="$MERGE_ROOT/trailing"
"$REPO_DIR/scripts/install.sh" \
    --root "$TRAILING_ROOT/" \
    --prefix /opt/auto-cleanup/ \
    --etc-dir /custom/etc/ \
    --skip-docker-config \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null
"$REPO_DIR/scripts/check.sh" \
    --root "$TRAILING_ROOT/" \
    --prefix /opt/auto-cleanup/ \
    --etc-dir /custom/etc/ \
    --skip-docker-config \
    --skip-btmp-logrotate \
    --skip-apt-periodic \
    --strict >/dev/null
grep -q 'ExecStart=/opt/auto-cleanup/sbin/vps-docker-clean' "$TRAILING_ROOT/custom/etc/systemd/system/vps-docker-clean.service"
if grep -q '//sbin\\|//default' "$TRAILING_ROOT/custom/etc/systemd/system/vps-docker-clean.service"; then
    echo "trailing slash paths produced doubled slashes in service" >&2
    exit 1
fi

# Drift detection for strict checks.
DRIFT_ROOT="$MERGE_ROOT/drift"
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
chmod 0644 "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted non-executable cleanup script" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
rm -f "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
ln -s /bin/true "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted symlinked cleanup script" >&2
    exit 1
fi
rm -f "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
mkdir -p "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted directory cleanup script path" >&2
    exit 1
fi
rm -rf "$DRIFT_ROOT/usr/local/sbin/vps-docker-clean"
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
sed -i 's/OnCalendar=weekly/OnCalendar=daily/' "$DRIFT_ROOT/etc/systemd/system/vps-docker-clean.timer"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted systemd timer policy" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
sed -i 's|ExecStart=/usr/local/sbin/vps-docker-clean|ExecStart=/bin/true|' "$DRIFT_ROOT/etc/systemd/system/vps-docker-clean.service"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted systemd service policy" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
sed -i 's/SystemMaxUse=300M/SystemMaxUse=999M/' "$DRIFT_ROOT/etc/systemd/journald.conf.d/auto-cleanup-limits.conf"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted journald policy" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
sed -i 's/maxsize 50M/maxsize 500M/' "$DRIFT_ROOT/etc/logrotate.d/auto-cleanup-btmp"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted btmp policy" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
sed -i 's/CleanInterval "30"/CleanInterval "300"/' "$DRIFT_ROOT/etc/apt/apt.conf.d/90auto-cleanup-periodic"
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted APT policy" >&2
    exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$DRIFT_ROOT" >/dev/null
python3 - "$DRIFT_ROOT/etc/docker/daemon.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["log-opts"]["tag"] = "{{.Name}}"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
if "$REPO_DIR/scripts/check.sh" --root "$DRIFT_ROOT" --strict >/dev/null 2>&1; then
    echo "check unexpectedly accepted drifted Docker log options" >&2
    exit 1
fi

"$REPO_DIR/scripts/install.sh" --root "$PARTIAL_ROOT/full" >/dev/null
"$REPO_DIR/scripts/uninstall.sh" \
    --root "$PARTIAL_ROOT/full" \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null
test -e "$PARTIAL_ROOT/full/etc/systemd/journald.conf.d/auto-cleanup-limits.conf"
test -e "$PARTIAL_ROOT/full/etc/logrotate.d/auto-cleanup-btmp"
test -e "$PARTIAL_ROOT/full/etc/apt/apt.conf.d/90auto-cleanup-periodic"
test ! -e "$PARTIAL_ROOT/full/usr/local/sbin/vps-docker-clean"

# Scheduled Docker cleanup compatibility and no-op paths.
BROKEN_ROOT="$MERGE_ROOT/broken-symlink"
mkdir -p "$BROKEN_ROOT/usr/local/sbin"
ln -s "$BROKEN_ROOT/missing-target" "$BROKEN_ROOT/usr/local/sbin/vps-docker-clean"
"$REPO_DIR/scripts/uninstall.sh" \
    --root "$BROKEN_ROOT" \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null
test ! -L "$BROKEN_ROOT/usr/local/sbin/vps-docker-clean"

DIRECTORY_REMOVE_ROOT="$MERGE_ROOT/directory-remove"
mkdir -p "$DIRECTORY_REMOVE_ROOT/usr/local/sbin/vps-docker-clean"
if "$REPO_DIR/scripts/uninstall.sh" \
    --root "$DIRECTORY_REMOVE_ROOT" \
    --skip-journald \
    --skip-btmp-logrotate \
    --skip-apt-periodic >/dev/null 2>&1; then
    echo "uninstall unexpectedly removed a directory destination" >&2
    exit 1
fi

mkdir -p "$FAKE_ROOT/bin"
cat > "$FAKE_ROOT/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "info" ]; then
    exit 0
fi
if [ "$1" = "buildx" ] && [ "$2" = "prune" ] && [ "$3" = "--help" ]; then
    echo "Usage: docker buildx prune"
    echo "      --reserved-space bytes"
fi
exit 0
EOF
chmod +x "$FAKE_ROOT/bin/docker"
FAKE_DOCKER_LOG="$FAKE_ROOT/docker.log" \
    BUILD_CACHE_UNTIL=24h \
    BUILD_CACHE_RESERVED=512MB \
    CONTAINER_UNTIL=48h \
    NETWORK_UNTIL=72h \
    IMAGE_UNTIL=1440h \
    DOCKER="$FAKE_ROOT/bin/docker" \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null

grep -q -- 'buildx prune -af --filter until=24h --reserved-space 512MB' "$FAKE_ROOT/docker.log"
grep -q -- 'container prune -f --filter until=48h' "$FAKE_ROOT/docker.log"
grep -q -- 'network prune -f --filter until=72h' "$FAKE_ROOT/docker.log"
grep -q -- 'image prune -af --filter until=1440h' "$FAKE_ROOT/docker.log"
if grep -Eq 'volume prune|--volumes' "$FAKE_ROOT/docker.log"; then
    echo "cleanup script attempted volume pruning" >&2
    exit 1
fi

cat > "$FAKE_ROOT/bin/docker-classic" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "info" ]; then
    exit 0
fi
if [ "$1" = "builder" ] && [ "$2" = "prune" ] && [ "$3" = "--help" ]; then
    echo "      --keep-storage bytes"
fi
exit 0
EOF
chmod +x "$FAKE_ROOT/bin/docker-classic"
FAKE_DOCKER_LOG="$FAKE_ROOT/docker-classic.log" \
    DOCKER="$FAKE_ROOT/bin/docker-classic" \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null
grep -q -- '--keep-storage 1GB' "$FAKE_ROOT/docker-classic.log"

cat > "$FAKE_ROOT/bin/docker-builder-reserved" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "info" ]; then
    exit 0
fi
if [ "$1" = "builder" ] && [ "$2" = "prune" ] && [ "$3" = "--help" ]; then
    echo "      --reserved-space bytes"
fi
exit 0
EOF
chmod +x "$FAKE_ROOT/bin/docker-builder-reserved"
FAKE_DOCKER_LOG="$FAKE_ROOT/docker-builder-reserved.log" \
    DOCKER="$FAKE_ROOT/bin/docker-builder-reserved" \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null
grep -q -- 'builder prune -af --filter until=168h --reserved-space 1GB' \
    "$FAKE_ROOT/docker-builder-reserved.log"

cat > "$FAKE_ROOT/bin/docker-fallback" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "info" ]; then
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_ROOT/bin/docker-fallback"
FAKE_DOCKER_LOG="$FAKE_ROOT/docker-fallback.log" \
    DOCKER="$FAKE_ROOT/bin/docker-fallback" \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null
grep -q -- 'builder prune -af --filter until=168h' "$FAKE_ROOT/docker-fallback.log"
if grep -Eq -- '--keep-storage|--reserved-space' "$FAKE_ROOT/docker-fallback.log"; then
    echo "fallback builder prune unexpectedly used a storage flag" >&2
    exit 1
fi

cat > "$FAKE_ROOT/bin/docker-no-builder" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = "info" ]; then
    exit 0
fi
if { [ "$1" = "builder" ] || [ "$1" = "buildx" ]; } &&
    [ "$2" = "prune" ] && [ "$3" = "--help" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$FAKE_ROOT/bin/docker-no-builder"
FAKE_DOCKER_LOG="$FAKE_ROOT/docker-no-builder.log" \
    DOCKER="$FAKE_ROOT/bin/docker-no-builder" \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null
if grep -q -- 'builder prune -af' "$FAKE_ROOT/docker-no-builder.log"; then
    echo "missing builder prune command unexpectedly ran build-cache prune" >&2
    exit 1
fi
grep -q -- 'container prune -f --filter until=168h' "$FAKE_ROOT/docker-no-builder.log"

cat > "$FAKE_ROOT/bin/docker-down" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE_ROOT/bin/docker-down"
DOCKER="$FAKE_ROOT/bin/docker-down" "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null
PATH="$FAKE_ROOT/empty-path" \
    DOCKER=docker \
    "$REPO_DIR/fixtures/bin/vps-docker-clean" >/dev/null

mkdir -p "$FAKE_ROOT/mode/etc/docker"
cat > "$FAKE_ROOT/mode/etc/docker/daemon.json" <<'EOF'
{"debug": false}
EOF
chmod 0600 "$FAKE_ROOT/mode/etc/docker/daemon.json"
owner_before=$(stat -c '%u:%g' "$FAKE_ROOT/mode/etc/docker/daemon.json")
"$REPO_DIR/lib/merge-docker-daemon.py" \
    --daemon-json "$FAKE_ROOT/mode/etc/docker/daemon.json" \
    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" >/dev/null
mode=$(stat -c '%a' "$FAKE_ROOT/mode/etc/docker/daemon.json")
test "$mode" = "600"
owner_after=$(stat -c '%u:%g' "$FAKE_ROOT/mode/etc/docker/daemon.json")
test "$owner_after" = "$owner_before"

echo "ok"
