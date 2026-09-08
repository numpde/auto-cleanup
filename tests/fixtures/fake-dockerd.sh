#!/bin/sh
set -eu

printf '%s\n' "$*" >> "${FAKE_DOCKERD_LOG:?missing FAKE_DOCKERD_LOG}"

case "$*" in
    --version)
        echo "Docker version ${FAKE_DOCKERD_VERSION:-28.0.0}, build test"
        exit 0
        ;;
    --validate\ --config-file\ *)
        ;;
    *)
        echo "unexpected dockerd arguments: $*" >&2
        exit 2
        ;;
esac

case "${FAKE_DOCKERD_MODE:-accept}" in
    accept) exit 0 ;;
    reject) echo 'injected daemon configuration rejection' >&2; exit 1 ;;
    *)
        echo "unknown FAKE_DOCKERD_MODE: $FAKE_DOCKERD_MODE" >&2
        exit 2
        ;;
esac
