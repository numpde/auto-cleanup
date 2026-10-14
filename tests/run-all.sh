#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"

for test_script in \
    "$SCRIPT_DIR/00_syntax.sh" \
    "$SCRIPT_DIR/01_manifest.sh" \
    "$SCRIPT_DIR/02_container_posture.sh" \
    "$SCRIPT_DIR/34_daemon_json.sh" \
    "$SCRIPT_DIR/41_native_btmp.sh" \
    "$SCRIPT_DIR/39_native_apt.sh" \
    "$SCRIPT_DIR/37_image_retention.sh" \
    "$SCRIPT_DIR/42_target_config.sh" \
    "$SCRIPT_DIR/43_target_lifecycle.sh" \
    "$SCRIPT_DIR/44_legacy_migration.sh"
do
    "$test_script"
done
