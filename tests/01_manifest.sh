#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

echo "manifest"
"$SCRIPT_DIR/check-manifest.sh" >/dev/null
echo "manifest ok"

