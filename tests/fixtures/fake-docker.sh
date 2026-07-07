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
    buildx-reserved:builder\ prune\ --help|fallback:builder\ prune\ --help|fail-container-prune:builder\ prune\ --help)
        echo "Usage: docker builder prune"
        exit 0
        ;;
    buildx-reserved:buildx\ prune\ --help)
        echo "Usage: docker buildx prune"
        echo "      --reserved-space bytes"
        exit 0
        ;;
    classic-keep:builder\ prune\ --help)
        echo "      --keep-storage bytes"
        exit 0
        ;;
    no-builder:builder\ prune\ --help|no-builder:buildx\ prune\ --help)
        exit 1
        ;;
esac

case "$*" in
    container\ prune\ -f\ --filter\ until=*|network\ prune\ -f\ --filter\ until=*|image\ prune\ -af\ --filter\ until=*)
        if [ "$mode" = "fail-container-prune" ] && [ "${1:-}" = "container" ]; then
            exit 42
        fi
        exit 0
        ;;
esac

case "$mode:$*" in
    fail-container-prune:builder\ prune\ -af\ --filter\ until=*)
        exit 0
        ;;
    buildx-reserved:builder\ prune\ -af\ --filter\ until=*)
        exit 0
        ;;
    buildx-reserved:buildx\ prune\ -af\ --filter\ until=*\ --reserved-space\ *)
        exit 0
        ;;
    classic-keep:builder\ prune\ -af\ --filter\ until=*\ --keep-storage\ *)
        exit 0
        ;;
    fallback:builder\ prune\ -af\ --filter\ until=*)
        exit 0
        ;;
esac

echo "unexpected fake Docker invocation for mode $mode: $*" >&2
exit 2
