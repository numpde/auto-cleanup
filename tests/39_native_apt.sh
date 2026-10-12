#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-apt-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
stage=$scratch/ignored
mkdir -p "$stage/etc/apt/apt.conf.d/nested"
printf '%s\n' 'APT::Periodic::AutocleanInterval "7";' > "$stage/etc/apt/apt.conf.d/10periodic.bak"
printf '%s\n' 'APT::Periodic::AutocleanInterval "7";' > "$stage/etc/apt/apt.conf.d/nested/10periodic"
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
test -e "$stage/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
rm "$stage/etc/apt/apt.conf.d/90auto-cleanup-periodic"
if "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >"$scratch/out" 2>&1; then
    echo 'ignored APT configuration accepted as active cleanup' >&2; exit 1
fi
grep -q 'bad.*effective APT cleanup' "$scratch/out"
for kind in late-override main-disable leading-zero-disable; do
    stage=$scratch/$kind
    mkdir -p "$stage/etc/apt/apt.conf.d"
    printf '%s\n' 'APT::Periodic::AutocleanInterval "7";' > "$stage/etc/apt/apt.conf.d/10periodic"
    case "$kind" in
        late-override)
            printf '%s\n' 'APT::Periodic::AutocleanInterval "0";' 'APT::Periodic::CleanInterval "0";' > "$stage/etc/apt/apt.conf.d/99disable" ;;
        leading-zero-disable)
            printf '%s\n' 'APT::Periodic::Enable "00";' > "$stage/etc/apt/apt.conf" ;;
        main-disable)
            printf '%s\n' 'APT::Periodic::Enable "0";' > "$stage/etc/apt/apt.conf" ;;
    esac
    if "$REPO_DIR/scripts/install.sh" --root "$stage" >"$scratch/out" 2>&1; then
        echo "disabled APT candidate accepted: $kind" >&2; exit 1
    fi
    grep -q 'existing settings disable the candidate' "$scratch/out"
    test ! -e "$stage/usr"
    test ! -e "$stage/etc/apt/apt.conf.d/90auto-cleanup-periodic"
done
stage=$scratch/reinstall
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
printf '%s\n' 'APT::Periodic::AutocleanInterval "1";' >> "$stage/etc/apt/apt.conf.d/90auto-cleanup-periodic"
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
for interval in 7d 1h 30m 60s; do
    stage=$scratch/interval-$interval
    mkdir -p "$stage/etc/apt/apt.conf.d"
    printf 'APT::Periodic::AutocleanInterval "%s";\n' "$interval" > "$stage/etc/apt/apt.conf.d/10periodic"
    "$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
    test ! -e "$stage/etc/apt/apt.conf.d/90auto-cleanup-periodic"
    "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
done
python3 - "$REPO_DIR" "$scratch" <<'PY'
import pathlib
import subprocess
import sys
root = pathlib.Path(sys.argv[2]) / 'back\\dir'
parts = root / 'apt.conf.d'
parts.mkdir(parents=True)
(parts / '10periodic').write_text('APT::Periodic::AutocleanInterval "7";\n')
result = subprocess.run(['python3', str(pathlib.Path(sys.argv[1]) / 'lib/apt-cleanup-policy.py'),
                         '--apt-dir', str(root)], text=True, capture_output=True)
assert result.returncode == 0, result.stderr
PY
echo 'native APT policy inspection ok'
