#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

for test_script in \
    "$SCRIPT_DIR/00_syntax.sh" \
    "$SCRIPT_DIR/01_manifest.sh" \
    "$SCRIPT_DIR/02_container_posture.sh" \
    "$SCRIPT_DIR/40_docs_contract.sh" \
    "$SCRIPT_DIR/30_functionality.sh"
do
    "$test_script"
done
