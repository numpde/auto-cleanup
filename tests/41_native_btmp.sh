#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-btmp-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
for kind in backup uncapped duplicate wrong-size wrong-size-only size-only size-multiple size-wildcard wrong-size-multiple wrong-size-wildcard mixed-matching mixed-conflicting mixed-reversed; do
    stage=$scratch/$kind
    mkdir -p "$stage/etc/logrotate.d"
    case "$kind" in
        backup) cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/btmp~" ;;
        uncapped) printf '%s\n' '/var/log/btmp {' ' monthly' ' missingok' '}' > "$stage/etc/logrotate.d/btmp" ;;
        duplicate)
            cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/one"
            cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/two" ;;
        wrong-size) sed 's/maxsize 50M/maxsize 100M/' "$REPO_DIR/fixtures/logrotate/btmp" > "$stage/etc/logrotate.d/btmp" ;;
        wrong-size-only) printf '%s\n' '/var/log/btmp {' '    size 100M' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        size-only) printf '%s\n' '/var/log/btmp {' '    size 50M' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        size-multiple) printf '%s\n' '/var/log/btmp /var/log/wtmp {' '    size 50M' '    missingok' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        size-wildcard) printf '%s\n' '/var/log/bt* {' '    size 50M' '    missingok' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        wrong-size-multiple) printf '%s\n' '/var/log/btmp /var/log/wtmp {' '    size 100M' '    missingok' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        wrong-size-wildcard) printf '%s\n' '/var/log/bt* {' '    size 100M' '    missingok' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        mixed-matching) printf '%s\n' '/var/log/btmp {' '    size 50M' '    maxsize 100M' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        mixed-conflicting) printf '%s\n' '/var/log/btmp {' '    size 10M' '    maxsize 50M' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
        mixed-reversed) printf '%s\n' '/var/log/btmp {' '    maxsize 50M' '    size 10M' '    rotate 1' '}' > "$stage/etc/logrotate.d/btmp" ;;
    esac
    if [ "$kind" = backup ]; then
        "$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null
        test -e "$stage/etc/logrotate.d/auto-cleanup-btmp"
        "$REPO_DIR/scripts/check.sh" host --root "$stage" >/dev/null
        rm "$stage/etc/logrotate.d/auto-cleanup-btmp"
        if "$REPO_DIR/scripts/check.sh" host --root "$stage" >"$scratch/out" 2>&1; then
            echo 'ignored btmp backup accepted by checker' >&2; exit 1
        fi
    elif [ "$kind" = size-only ] || [ "$kind" = size-multiple ] || [ "$kind" = size-wildcard ] || [ "$kind" = mixed-matching ]; then
        "$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null
        test ! -e "$stage/etc/logrotate.d/auto-cleanup-btmp"
        "$REPO_DIR/scripts/check.sh" host --root "$stage" >/dev/null
    else
        if "$REPO_DIR/scripts/install.sh" host --root "$stage" >"$scratch/out" 2>&1; then
            echo "conflicting btmp configuration accepted: $kind" >&2; exit 1
        fi
        grep -q 'Cannot inspect btmp' "$scratch/out"
        test ! -e "$stage/usr"
        test ! -e "$stage/etc/logrotate.d/auto-cleanup-btmp"
    fi
done
python3 - "$REPO_DIR/lib/btmp-policy.py" <<'PY'
import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys

spec = importlib.util.spec_from_file_location('btmp_policy', sys.argv[1])
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
output = ('Handling 1 logs\nrotating pattern: /var/log/bt*  52428800 bytes (test)\n'
          'considering log /var/log/bt*\n')
result = SimpleNamespace(stdout='', stderr=output, returncode=0)
with patch.object(policy.os.path, 'exists', return_value=False), \
        patch.object(policy.subprocess, 'run', return_value=result):
    try:
        policy.inspect_size(Path(sys.argv[1]))
    except ValueError as error:
        assert 'wildcard coverage' in str(error)
    else:
        raise AssertionError('absent btmp with wildcard was accepted')
PY
stage=$scratch/reinstall
"$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null
sed -i '/compress/d' "$stage/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" host --root "$stage" >/dev/null
stage=$scratch/group-umask
(umask 002; "$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null)
"$REPO_DIR/scripts/check.sh" host --root "$stage" >/dev/null
(umask 002; "$REPO_DIR/scripts/install.sh" host --root "$stage" >/dev/null)
echo 'native btmp policy inspection ok'
