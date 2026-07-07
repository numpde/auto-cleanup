#!/bin/sh

if [ "${AUTO_CLEANUP_TEST_CONTAINER:-}" != "1" ]; then
    echo "tests must run inside the test container; use: make test" >&2
    exit 2
fi

if [ ! -f /.dockerenv ] &&
    ! grep -qaE '/(docker|containerd|kubepods)(/|$)' /proc/1/cgroup 2>/dev/null; then
    echo "tests must run inside a Docker/containerd test container; use: make test" >&2
    exit 2
fi
