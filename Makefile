SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TEST_CONTAINER := ./scripts/test-container.sh

.PHONY: help test test/all test/matrix test/root-container test/posture shell

help:
	@printf '%s\n' \
		'auto-cleanup targets' \
		'' \
		'Verification:' \
		'  make test     Build the pinned test image and run tests in a locked container.' \
		'  make test/all Run posture, matrix, and root metadata lanes.' \
		'  make test/matrix  Run Debian and Ubuntu container lanes.' \
		'  make test/root-container  Run narrow root metadata checks.' \
		'  make test/posture  Run build-context canary checks.' \
		'' \
		'Debug:' \
		'  make shell    Open a shell in the copied-context test image.'

test:
	@$(TEST_CONTAINER) test

test/all: test/posture test/matrix test/root-container

test/matrix:
	@$(TEST_CONTAINER) test/matrix

test/root-container:
	@$(TEST_CONTAINER) test/root-container

test/posture:
	@$(TEST_CONTAINER) test/posture

shell:
	@$(TEST_CONTAINER) shell
