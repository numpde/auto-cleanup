#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
python3 "$SCRIPT_DIR/effective_units.py"
