#!/bin/sh
set -eu

printf '%s\n' "$*" >> "${FAKE_DOCKERD_LOG:?missing FAKE_DOCKERD_LOG}"

case "$*" in
    --validate\ --config-file\ *)
        ;;
    *)
        echo "unexpected dockerd arguments: $*" >&2
        exit 2
        ;;
esac

case "${FAKE_DOCKERD_MODE:-accept}" in
    accept) exit 0 ;;
    reject) exit 1 ;;
    *)
        echo "unknown FAKE_DOCKERD_MODE: $FAKE_DOCKERD_MODE" >&2
        exit 2
        ;;
esac
