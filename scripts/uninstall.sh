#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
    host|docker) scope=$1; shift ;;
    -h|--help) exec "$SCRIPT_DIR/auto-cleanup" --help ;;
    *) echo "Usage: uninstall.sh host|docker [options]; use scripts/auto-cleanup for list or migration." >&2; exit 2 ;;
esac
exec "$SCRIPT_DIR/auto-cleanup" "$scope" remove "$@"
