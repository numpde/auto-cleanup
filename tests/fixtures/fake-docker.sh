#!/bin/sh
set -eu

mode=${FAKE_DOCKER_MODE:-accept}

if [ "${1:-}" != --host ] || [ "${2:-}" != unix:///var/run/docker.sock ]; then
    echo "cleanup must select the local rootful Docker daemon" >&2
    exit 2
fi
shift 2

if [ "$mode" = "down" ]; then
    exit 1
fi

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?missing FAKE_DOCKER_LOG}"

if [ "${1:-}" = "info" ]; then
    printf '%s\n' '{"ID":"test-daemon","DockerRootDir":"/tmp"}'
    exit 0
fi
case "$*" in
    'container ls -aq --no-trunc') exit 0 ;;
    'image ls -aq --no-trunc')
        printf '%s\n' sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        exit 0 ;;
    image\ inspect\ example.test/app@sha256:*)
        printf '%s\n' '[{"Id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","RepoDigests":["example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Created":"2020-01-01T00:00:00Z"}]'
        exit 0 ;;
    image\ inspect\ sha256:bbbb*)
        printf '%s\n' '[{"Id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","Created":"2020-01-01T00:00:00Z"}]'
        exit 0 ;;
esac

case "$*" in
    container\ prune\ -f\ --filter\ until=*\ --filter\ label=auto-cleanup.disposable=true|network\ prune\ -f\ --filter\ until=*|image\ rm\ --no-prune\ sha256:*)
        if [ "$mode" = "fail-container-prune" ] && [ "${1:-}" = "container" ]; then
            exit 42
        fi
        exit 0
        ;;
esac

echo "unexpected fake Docker invocation for mode $mode: $*" >&2
exit 2
