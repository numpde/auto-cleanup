#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-btmp-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
for kind in backup uncapped duplicate wrong-size; do
    stage=$scratch/$kind
    mkdir -p "$stage/etc/logrotate.d"
    case "$kind" in
        backup) cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/btmp.bak" ;;
        uncapped) printf '%s\n' '/var/log/btmp {' ' monthly' ' missingok' '}' > "$stage/etc/logrotate.d/btmp" ;;
        duplicate)
            cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/one"
            cp "$REPO_DIR/fixtures/logrotate/btmp" "$stage/etc/logrotate.d/two" ;;
        wrong-size) sed 's/maxsize 50M/maxsize 100M/' "$REPO_DIR/fixtures/logrotate/btmp" > "$stage/etc/logrotate.d/btmp" ;;
    esac
    if [ "$kind" = backup ]; then
        "$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
        test -e "$stage/etc/logrotate.d/auto-cleanup-btmp"
        "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
        rm "$stage/etc/logrotate.d/auto-cleanup-btmp"
        if "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >"$scratch/out" 2>&1; then
            echo 'ignored btmp backup accepted by checker' >&2; exit 1
        fi
    else
        if "$REPO_DIR/scripts/install.sh" --root "$stage" >"$scratch/out" 2>&1; then
            echo "conflicting btmp configuration accepted: $kind" >&2; exit 1
        fi
        grep -q 'Cannot inspect btmp' "$scratch/out"
        test ! -e "$stage/usr"
        test ! -e "$stage/etc/logrotate.d/auto-cleanup-btmp"
    fi
done
stage=$scratch/reinstall
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
sed -i '/compress/d' "$stage/etc/logrotate.d/auto-cleanup-btmp"
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
stage=$scratch/group-umask
(umask 002; "$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null)
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
(umask 002; "$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null)
echo 'native btmp policy inspection ok'
