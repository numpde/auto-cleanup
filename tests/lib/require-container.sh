#!/bin/sh

if [ "${AUTO_CLEANUP_TEST_CONTAINER:-}" != "1" ]; then
    echo "tests must run inside the test container; use: make test" >&2
    exit 2
fi

