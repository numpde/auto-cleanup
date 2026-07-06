#!/bin/sh
set -eu

mode=${FAKE_DOCKER_MODE:-buildx-reserved}

if [ "$mode" = "down" ]; then
    exit 1
fi

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?missing FAKE_DOCKER_LOG}"

if [ "${1:-}" = "info" ]; then
    exit 0
fi

case "$mode:$*" in
    buildx-reserved:buildx\ prune\ --help)
        echo "Usage: docker buildx prune"
        echo "      --reserved-space bytes"
        ;;
    classic-keep:builder\ prune\ --help)
        echo "      --keep-storage bytes"
        ;;
    builder-reserved:builder\ prune\ --help)
        echo "      --reserved-space bytes"
        ;;
    no-builder:builder\ prune\ --help|no-builder:buildx\ prune\ --help)
        exit 1
        ;;
esac

exit 0

