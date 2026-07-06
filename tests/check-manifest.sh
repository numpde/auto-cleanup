#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
MANIFEST="$REPO_DIR/fixtures/install-manifest.tsv"

if [ ! -f "$REPO_DIR/scripts/lib/common.sh" ]; then
    echo "missing support file: scripts/lib/common.sh" >&2
    exit 1
fi
if [ ! -f "$REPO_DIR/lib/merge-docker-daemon.py" ]; then
    echo "missing support file: lib/merge-docker-daemon.py" >&2
    exit 1
fi
common_mode=$(stat -c '%a' "$REPO_DIR/scripts/lib/common.sh")
if [ "$common_mode" != "644" ]; then
    echo "support file mode mismatch for scripts/lib/common.sh: expected 644, got $common_mode" >&2
    exit 1
fi
merge_mode=$(stat -c '%a' "$REPO_DIR/lib/merge-docker-daemon.py")
if [ "$merge_mode" != "755" ]; then
    echo "support file mode mismatch for lib/merge-docker-daemon.py:" \
        "expected 755, got $merge_mode" >&2
    exit 1
fi

duplicate_dsts=$(awk -F '	' 'seen[$4]++ { print $4 }' "$MANIFEST")
if [ -n "$duplicate_dsts" ]; then
    echo "duplicate manifest destination(s):" >&2
    printf '%s\n' "$duplicate_dsts" >&2
    exit 1
fi

while IFS='	' read -r kind mode src dst; do
    case "$kind" in
        file|template|conditional) ;;
        *)
            echo "invalid manifest kind: $kind" >&2
            exit 1
            ;;
    esac
    case "$mode" in
        0644|0755) ;;
        *)
            echo "invalid manifest mode for $src: $mode" >&2
            exit 1
            ;;
    esac
    case "$dst" in
        /*) ;;
        *)
            echo "manifest destination must be absolute: $dst" >&2
            exit 1
            ;;
    esac
    if [ ! -f "$REPO_DIR/$src" ]; then
        echo "missing manifest source: $src" >&2
        exit 1
    fi
    actual_mode=$(stat -c '%a' "$REPO_DIR/$src")
    if [ "0$actual_mode" != "$mode" ]; then
        echo "manifest mode mismatch for $src: expected $mode, got $actual_mode" >&2
        exit 1
    fi
done < "$MANIFEST"

echo "manifest ok"
