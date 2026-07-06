#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --root DIR              Stage files under DIR instead of the real filesystem
  --prefix DIR            Prefix for installed executables (default: /usr/local)
  --etc-dir DIR           Configuration root (default: /etc)
  --dry-run               Print intended actions without installing files
  --skip-docker-config    Do not merge Docker daemon logging config
  --skip-journald         Do not install the journald limits fixture
  --skip-btmp-logrotate   Do not install the btmp logrotate fixture
  --skip-apt-periodic     Do not install the APT periodic cleanup fixture
  --restart-docker        Restart Docker after updating daemon.json
  --no-enable-timer       Do not enable/start the systemd timer
  --no-service-actions    Do not run systemctl actions after installing files
  -h, --help              Show this help
EOF
}

ROOT=
PREFIX=/usr/local
ETC_DIR=/etc
DRY_RUN=0
SKIP_DOCKER_CONFIG=0
RESTART_DOCKER=0
ENABLE_TIMER=1
SYSTEMD_ACTIONS=1
SKIP_BTMP_LOGROTATE=0
SKIP_APT_PERIODIC=0
SKIP_JOURNALD=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            ROOT=${2:?--root requires a directory}
            shift 2
            ;;
        --prefix)
            PREFIX=${2:?--prefix requires a directory}
            shift 2
            ;;
        --etc-dir)
            ETC_DIR=${2:?--etc-dir requires a directory}
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-docker-config)
            SKIP_DOCKER_CONFIG=1
            shift
            ;;
        --skip-journald)
            SKIP_JOURNALD=1
            shift
            ;;
        --skip-btmp-logrotate)
            SKIP_BTMP_LOGROTATE=1
            shift
            ;;
        --skip-apt-periodic)
            SKIP_APT_PERIODIC=1
            shift
            ;;
        --restart-docker)
            RESTART_DOCKER=1
            shift
            ;;
        --no-enable-timer)
            ENABLE_TIMER=0
            shift
            ;;
        --no-service-actions)
            SYSTEMD_ACTIONS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
COMMON_SH="$REPO_DIR/scripts/lib/common.sh"
if [ ! -f "$COMMON_SH" ]; then
    echo "missing support file: $COMMON_SH" >&2
    exit 1
fi
. "$COMMON_SH"

PREFIX=$(trim_trailing_slashes "$PREFIX")
ETC_DIR=$(trim_trailing_slashes "$ETC_DIR")
if [ -n "$ROOT" ]; then
    ROOT=$(trim_trailing_slashes "$ROOT")
fi

validate_path --prefix "$PREFIX"
validate_path --etc-dir "$ETC_DIR"

if [ "$ETC_DIR" != "/etc" ]; then
    SYSTEMD_ACTIONS=0
fi

if [ -n "$ROOT" ]; then
    validate_path --root "$ROOT"
    SYSTEMD_ACTIONS=0
fi

target() {
    printf '%s%s\n' "$ROOT" "$1"
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would run:'
        for arg in "$@"; do
            printf ' %s' "$arg"
        done
        printf '\n'
    else
        "$@"
    fi
}

print_next_steps() {
    if [ -n "$ROOT" ] || [ "$ETC_DIR" != "/etc" ] || [ "$PREFIX" != "/usr/local" ]; then
        return
    fi
    if [ "$SYSTEMD_ACTIONS" -ne 1 ] || ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo
        echo "After a real install, quick verification:"
    else
        echo
        echo "Quick verification:"
    fi
    echo
    echo "  systemctl status vps-docker-clean.timer"
    echo "  systemctl list-timers vps-docker-clean.timer"
    if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
        echo "  cat /etc/docker/daemon.json"
    fi

    if [ "$SKIP_DOCKER_CONFIG" -eq 0 ] && [ "$RESTART_DOCKER" -eq 0 ]; then
        echo
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "For Docker defaults to apply after a real install:"
        else
            echo "For Docker defaults to apply later:"
        fi
        echo
        echo "  systemctl restart docker"
        echo "  docker compose up -d --force-recreate"
    fi
}

install_file() {
    src=$1
    dst=$2
    mode=$3
    display_src=${4:-$src}
    dst_dir=$(dirname -- "$dst")
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would install: $display_src -> $dst mode $mode"
        return
    fi
    run install -d -m 0755 "$dst_dir"
    run install -m "$mode" "$src" "$dst"
}

assert_install_destination() {
    path=$1
    if [ -L "$path" ]; then
        echo "refusing to replace symlink: $path" >&2
        exit 1
    fi
    if [ -e "$path" ] && [ ! -f "$path" ]; then
        echo "refusing to replace non-regular file: $path" >&2
        exit 1
    fi
}

require_file() {
    path=$1
    if [ ! -f "$path" ]; then
        echo "missing source file: $path" >&2
        exit 1
    fi
}

require_executable() {
    path=$1
    require_file "$path"
    if [ ! -x "$path" ]; then
        echo "source file is not executable: $path" >&2
        exit 1
    fi
}

BIN_DIR=$(target "$PREFIX/sbin")
SYSTEMD_DIR=$(target "$ETC_DIR/systemd/system")
JOURNALD_DIR=$(target "$ETC_DIR/systemd/journald.conf.d")
LOGROTATE_DIR=$(target "$ETC_DIR/logrotate.d")
APT_CONF_DIR=$(target "$ETC_DIR/apt/apt.conf.d")
DOCKER_DIR=$(target "$ETC_DIR/docker")
DAEMON_JSON="$DOCKER_DIR/daemon.json"

require_file "$REPO_DIR/fixtures/bin/vps-docker-clean"
require_file "$REPO_DIR/fixtures/systemd/vps-docker-clean.service"
require_file "$REPO_DIR/fixtures/systemd/vps-docker-clean.timer"
if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
    require_executable "$REPO_DIR/lib/merge-docker-daemon.py"
    require_file "$REPO_DIR/fixtures/docker/daemon-log-policy.json"
fi
if [ "$SKIP_JOURNALD" -eq 0 ]; then
    require_file "$REPO_DIR/fixtures/journald/limits.conf"
fi
if [ "$SKIP_BTMP_LOGROTATE" -eq 0 ]; then
    require_file "$REPO_DIR/fixtures/logrotate/btmp"
fi
if [ "$SKIP_APT_PERIODIC" -eq 0 ]; then
    require_file "$REPO_DIR/fixtures/apt/10periodic-cleanup"
fi

if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required for Docker daemon JSON; use --skip-docker-config to skip." >&2
        exit 1
    fi
    "$REPO_DIR/lib/merge-docker-daemon.py" \
        --daemon-json "$DAEMON_JSON" \
        --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
        --dry-run >/dev/null
fi

assert_install_destination "$BIN_DIR/vps-docker-clean"
assert_install_destination "$SYSTEMD_DIR/vps-docker-clean.service"
assert_install_destination "$SYSTEMD_DIR/vps-docker-clean.timer"
if [ "$SKIP_JOURNALD" -eq 0 ]; then
    assert_install_destination "$JOURNALD_DIR/auto-cleanup-limits.conf"
fi
if [ "$SKIP_BTMP_LOGROTATE" -eq 0 ]; then
    assert_install_destination "$LOGROTATE_DIR/auto-cleanup-btmp"
fi
if [ "$SKIP_APT_PERIODIC" -eq 0 ]; then
    assert_install_destination "$APT_CONF_DIR/90auto-cleanup-periodic"
fi

TMP_SERVICE=$(mktemp)
trap 'rm -f "$TMP_SERVICE"' EXIT INT TERM
sed \
    -e "s|@SBIN_DIR@|$PREFIX/sbin|g" \
    -e "s|@ETC_DIR@|$ETC_DIR|g" \
    "$REPO_DIR/fixtures/systemd/vps-docker-clean.service" > "$TMP_SERVICE"
if grep -q '@[A-Z_][A-Z_]*@' "$TMP_SERVICE"; then
    echo "unresolved placeholder in rendered systemd service" >&2
    exit 1
fi

install_file "$REPO_DIR/fixtures/bin/vps-docker-clean" "$BIN_DIR/vps-docker-clean" 0755
install_file \
    "$TMP_SERVICE" \
    "$SYSTEMD_DIR/vps-docker-clean.service" \
    0644 \
    "$REPO_DIR/fixtures/systemd/vps-docker-clean.service (rendered)"
install_file \
    "$REPO_DIR/fixtures/systemd/vps-docker-clean.timer" \
    "$SYSTEMD_DIR/vps-docker-clean.timer" \
    0644
if [ "$SKIP_JOURNALD" -eq 0 ]; then
    install_file \
        "$REPO_DIR/fixtures/journald/limits.conf" \
        "$JOURNALD_DIR/auto-cleanup-limits.conf" \
        0644
fi
if [ "$SKIP_BTMP_LOGROTATE" -eq 0 ]; then
    if ! has_existing_btmp_policy "$LOGROTATE_DIR"; then
        install_file \
            "$REPO_DIR/fixtures/logrotate/btmp" \
            "$LOGROTATE_DIR/auto-cleanup-btmp" \
            0644
    else
        echo "Skipped btmp fixture; existing size-based policy found in $LOGROTATE_DIR."
    fi
fi
if [ "$SKIP_APT_PERIODIC" -eq 0 ]; then
    if ! has_existing_apt_cleanup_policy "$APT_CONF_DIR"; then
        install_file \
            "$REPO_DIR/fixtures/apt/10periodic-cleanup" \
            "$APT_CONF_DIR/90auto-cleanup-periodic" \
            0644
    else
        echo "Skipped APT fixture; existing cleanup policy found in $APT_CONF_DIR."
    fi
fi

if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would ensure directory: $DOCKER_DIR mode 0755"
        echo "would merge: $REPO_DIR/fixtures/docker/daemon-log-policy.json -> $DAEMON_JSON"
    else
        install -d -m 0755 "$DOCKER_DIR"
        "$REPO_DIR/lib/merge-docker-daemon.py" \
            --daemon-json "$DAEMON_JSON" \
            --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json"
    fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
    echo "Installed auto-cleanup files."
fi
if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "Docker daemon logging config would be checked/updated at $DAEMON_JSON."
    else
        echo "Docker daemon logging config was checked/updated at $DAEMON_JSON."
    fi
    echo "Existing containers must be recreated before they use daemon-level logging changes."
fi

if [ "$SYSTEMD_ACTIONS" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    if [ "$ENABLE_TIMER" -eq 1 ]; then
        run systemctl enable --now vps-docker-clean.timer
    fi
    if [ "$SKIP_JOURNALD" -eq 0 ]; then
        run systemctl restart systemd-journald
    fi
    if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
        if [ "$RESTART_DOCKER" -eq 1 ]; then
            run systemctl restart docker
        else
            echo "Docker was not restarted. Restart Docker and recreate containers when convenient."
        fi
    fi
else
    echo "Skipped systemd service actions."
fi

print_next_steps

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run complete; no files were installed."
fi
