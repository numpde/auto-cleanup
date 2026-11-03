SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TEST_CONTAINER := ./scripts/test-container.sh
CONFIG_DIR ?= $(CURDIR)/tmp/docker-configs
export CONFIG_DIR

.PHONY: help docker/configs docker/configs/check docker/install/preview docker/install docker/check test test/all test/matrix test/root-container test/posture shell

help:
	@printf '%s\n' \
		'auto-cleanup targets' \
		'' \
		'Docker targets (CONFIG_DIR defaults to ./tmp/docker-configs):' \
		'  make docker/configs  Create configs for accessible local Docker contexts.' \
		'  make docker/configs/check  Inspect configs and their Docker engines.' \
		'  make docker/install/preview  Preview every installation without managed changes.' \
		'  make docker/install  Enroll the selected engine configurations.' \
		'  make docker/check    Check the selected engines and effective units.' \
		'  Run install and check with sudo.' \
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

docker/configs:
	@python3 scripts/docker-context-configs.py "$$CONFIG_DIR"

docker/configs/check:
	@python3 scripts/docker-context-configs.py --check "$$CONFIG_DIR"

docker/install/preview:
	@test -n "$${CONFIG_DIR:-}" || { echo 'Set CONFIG_DIR' >&2; exit 1; }
	@shopt -s nullglob; files=("$$CONFIG_DIR"/*.json); \
	(($${#files[@]})) || { echo "No JSON configs in $$CONFIG_DIR" >&2; exit 1; }; \
	for file in "$${files[@]}"; do \
		engine=$${file##*/}; engine=$${engine%.json}; \
		[[ $$engine =~ ^[a-z_][a-z0-9_-]{0,31}$$ ]] || { echo "Invalid engine name: $$engine" >&2; exit 1; }; \
		python3 -c 'import sys; sys.path.insert(0, "fixtures/bin"); from auto_cleanup_config import load_target; name = load_target(sys.argv[1], trusted=True)["name"]; sys.exit(0 if name == sys.argv[2] else "Config name does not match " + sys.argv[2])' "$$file" "$$engine"; \
	done; \
	python3 scripts/docker-context-configs.py --check "$$CONFIG_DIR"; \
	for file in "$${files[@]}"; do \
		engine=$${file##*/}; engine=$${engine%.json}; \
		echo "Previewing $$engine"; \
		./scripts/auto-cleanup docker install --config "$$file" --dry-run; \
	done

docker/install: docker/install/preview
	@shopt -s nullglob; files=("$$CONFIG_DIR"/*.json); \
	for file in "$${files[@]}"; do \
		engine=$${file##*/}; engine=$${engine%.json}; \
		echo "Installing $$engine"; \
		./scripts/auto-cleanup docker install --config "$$file"; \
	done

docker/check:
	@targets=$$(./scripts/auto-cleanup docker list); \
	[[ -n $$targets ]] || { echo 'No engines enrolled' >&2; exit 1; }; \
	while read -r engine rest; do \
		echo "Checking $$engine"; \
		./scripts/auto-cleanup docker check "$$engine" --live; \
	done <<< "$$targets"

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
