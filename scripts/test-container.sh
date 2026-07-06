#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/test-container.sh test
  ./scripts/test-container.sh test/matrix
  ./scripts/test-container.sh test/root-container
  ./scripts/test-container.sh test/posture
  ./scripts/test-container.sh shell

Environment:
  DOCKER_CLI                    Container engine command. Default: docker.
  AUTO_CLEANUP_ALLOW_ROOT_TESTS Set to 1 to allow running this wrapper as host uid 0.
EOF
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_cli="${DOCKER_CLI:-docker}"
mode="${1:-test}"

case "$mode" in
  test|test/matrix|test/root-container|test/posture|shell) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "$(id -u)" == "0" && "${AUTO_CLEANUP_ALLOW_ROOT_TESTS:-}" != "1" ]]; then
  echo "Refusing to run Docker test lanes as host uid 0." >&2
  echo "Run make test as a non-root user, or set AUTO_CLEANUP_ALLOW_ROOT_TESTS=1 for a deliberate exception." >&2
  exit 2
fi

if ! command -v "$docker_cli" >/dev/null 2>&1; then
  echo "Container engine not found: $docker_cli" >&2
  exit 1
fi

readonly debian_base_image="docker.io/library/debian:12-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df"
readonly ubuntu_base_image="docker.io/library/ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90"

lane_base_image() {
  case "$1" in
    debian-12-slim) printf '%s\n' "$debian_base_image" ;;
    ubuntu-24.04) printf '%s\n' "$ubuntu_base_image" ;;
    *)
      echo "Unknown matrix lane: $1" >&2
      exit 2
      ;;
  esac
}

lane_image_tag() {
  case "$1" in
    debian-12-slim|ubuntu-24.04) printf 'auto-cleanup-test:%s\n' "$1" ;;
    *)
      echo "Unknown matrix lane: $1" >&2
      exit 2
      ;;
  esac
}

validate_lane_ref() {
  lane=$1
  image_ref=$(lane_base_image "$lane")
  case "$lane" in
    *[!A-Za-z0-9._-]*)
      echo "Invalid matrix lane name: $lane" >&2
      exit 2
      ;;
  esac
  case "$image_ref" in
    *@sha256:*) ;;
    *)
      echo "Test base image must be digest-pinned: $image_ref" >&2
      exit 2
      ;;
  esac
}

build_image() {
  lane=$1
  context_dir=${2:-$root_dir}
  validate_lane_ref "$lane"
  base_image=$(lane_base_image "$lane")
  image_tag=$(lane_image_tag "$lane")
  echo "Building test image: $image_tag"
  echo "Base image: $base_image"
  "$docker_cli" build \
    --build-arg "BASE_IMAGE=$base_image" \
    -f "$context_dir/containers/test/Containerfile" \
    -t "$image_tag" \
    "$context_dir"
}

run_broad_lane() {
  lane=$1
  image_tag=$(lane_image_tag "$lane")
  echo "Running test lane: $lane"
  "$docker_cli" run \
    --rm \
    --init \
    --pull=never \
    --user 65532:65532 \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 256 \
    --memory 512m \
    --memory-swap 512m \
    --env AUTO_CLEANUP_TEST_CONTAINER=1 \
    --env HOME=/tmp/home \
    --env TMPDIR=/run/auto-cleanup-test \
    --env PYTHONDONTWRITEBYTECODE=1 \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m,mode=1777 \
    --tmpfs /run/auto-cleanup-test:rw,nosuid,nodev,exec,size=256m,mode=1777 \
    --workdir /work \
    "$image_tag" /bin/sh /work/tests/run-all.sh
}

run_root_lane() {
  lane=debian-12-slim
  image_tag=$(lane_image_tag "$lane")
  echo "Running root metadata lane: $lane"
  "$docker_cli" run \
    --rm \
    --init \
    --pull=never \
    --user 0:0 \
    --network none \
    --read-only \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --pids-limit 128 \
    --memory 256m \
    --memory-swap 256m \
    --env AUTO_CLEANUP_TEST_CONTAINER=1 \
    --env AUTO_CLEANUP_TEST_ROOT_CONTAINER=1 \
    --env HOME=/tmp/home \
    --env TMPDIR=/run/auto-cleanup-test \
    --env PYTHONDONTWRITEBYTECODE=1 \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=128m,mode=1777 \
    --tmpfs /run/auto-cleanup-test:rw,nosuid,nodev,exec,size=128m,mode=1777 \
    --workdir /work \
    "$image_tag" /bin/sh /work/tests/root-metadata.sh
}

run_build_context_canary() {
  lane=debian-12-slim
  build_image "$lane"
  canary="auto-cleanup-build-context-canary-$$"
  tmp_context=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-context.XXXXXX")
  cleanup_context() {
    rm -rf "$tmp_context"
  }
  trap cleanup_context EXIT
  cp -a "$root_dir/." "$tmp_context/"
  mkdir -p "$tmp_context/.git" "$tmp_context/.agents" "$tmp_context/.codex" "$tmp_context/__pycache__" "$tmp_context/tmp"
  printf '%s\n' "$canary" > "$tmp_context/.git/$canary"
  printf '%s\n' "$canary" > "$tmp_context/.agents/$canary"
  printf '%s\n' "$canary" > "$tmp_context/.codex/$canary"
  printf '%s\n' "$canary" > "$tmp_context/__pycache__/$canary.pyc"
  printf '%s\n' "$canary" > "$tmp_context/tmp/$canary.tmp"
  printf '%s\n' "$canary" > "$tmp_context/.env"
  printf '%s\n' "$canary" > "$tmp_context/id_rsa"
  printf '%s\n' "$canary" > "$tmp_context/local.log"
  build_image "$lane" "$tmp_context"
  image_tag=$(lane_image_tag "$lane")
  "$docker_cli" run \
    --rm \
    --init \
    --pull=never \
    --user 65532:65532 \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 64 \
    --memory 128m \
    --memory-swap 128m \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
    --workdir /work \
    "$image_tag" /bin/sh -eu -c \
      'for path in ".git" ".agents" ".codex" "__pycache__" "tmp" ".env" "id_rsa" "local.log"; do test ! -e "/work/$path"; done'
  cleanup_context
  trap - EXIT
  echo "build context canary ok"
}

case "$mode" in
  test)
    build_image debian-12-slim
    run_broad_lane debian-12-slim
    ;;
  test/matrix)
    for lane in debian-12-slim ubuntu-24.04; do
      build_image "$lane"
      run_broad_lane "$lane"
    done
    ;;
  test/root-container)
    build_image debian-12-slim
    run_root_lane
    ;;
  test/posture)
    run_build_context_canary
    ;;
  shell)
    lane=debian-12-slim
    build_image "$lane"
    image_tag=$(lane_image_tag "$lane")
    interactive_options=()
    if [[ -t 0 && -t 1 ]]; then
      interactive_options=(-it)
    fi
    echo "Opening contained shell: $lane"
    "$docker_cli" run \
      "${interactive_options[@]}" \
      --rm \
      --init \
      --pull=never \
      --user 65532:65532 \
      --network none \
      --read-only \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      --pids-limit 256 \
      --memory 512m \
      --memory-swap 512m \
      --env AUTO_CLEANUP_TEST_CONTAINER=1 \
      --env HOME=/tmp/home \
      --env TMPDIR=/run/auto-cleanup-test \
      --env PYTHONDONTWRITEBYTECODE=1 \
      --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m,mode=1777 \
      --tmpfs /run/auto-cleanup-test:rw,nosuid,nodev,exec,size=256m,mode=1777 \
      --workdir /work \
      "$image_tag" /bin/sh
    ;;
esac
