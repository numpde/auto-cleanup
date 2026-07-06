#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: uninstall.sh [options]

Options:
  --root DIR                         Remove staged files under DIR
  --prefix DIR                       Prefix for installed executables (default: /usr/local)
  --etc-dir DIR                      Configuration root (default: /etc)
  --dry-run                          Print intended actions without removing files
  --restore-docker-backup FILE       Restore daemon.json from an explicit backup file
  --skip-journald                    Do not remove journald limits policy
  --skip-btmp-logrotate              Do not remove btmp logrotate policy
  --skip-apt-periodic                Do not remove APT periodic cleanup policy
  --no-service-actions               Do not run systemctl actions
  -h, --help                         Show this help
EOF
}

ROOT=
PREFIX=/usr/local
ETC_DIR=/etc
DRY_RUN=0
RESTORE_DOCKER_BACKUP=
SYSTEMD_ACTIONS=1
SKIP_JOURNALD=0
SKIP_BTMP_LOGROTATE=0
SKIP_APT_PERIODIC=0

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
        --restore-docker-backup)
            RESTORE_DOCKER_BACKUP=${2:?--restore-docker-backup requires a file}
            shift 2
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

if [ -n "$RESTORE_DOCKER_BACKUP" ]; then
    RESTORE_DOCKER_BACKUP=$(trim_trailing_slashes "$RESTORE_DOCKER_BACKUP")
    validate_path --restore-docker-backup "$RESTORE_DOCKER_BACKUP"
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

print_restore_next_steps() {
    if [ -z "$RESTORE_DOCKER_BACKUP" ]; then
        return
    fi
    if [ -n "$ROOT" ] || [ "$ETC_DIR" != "/etc" ]; then
        return
    fi
    if [ "$SYSTEMD_ACTIONS" -ne 1 ] || ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    echo
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "After restoring Docker daemon config in a real uninstall:"
    else
        echo "After restoring Docker daemon config:"
    fi
    echo
    echo "  systemctl restart docker"
    echo "  # then recreate each Compose-managed workload from that workload's Compose project directory:"
    echo "  docker compose up -d --force-recreate"
}

remove_file() {
    path=$1
    if [ -L "$path" ]; then
        run rm -f "$path"
    elif [ -e "$path" ] && [ ! -f "$path" ]; then
        echo "refusing to remove non-regular file: $path" >&2
        exit 1
    elif [ -e "$path" ]; then
        run rm -f "$path"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "would remove if present: $path"
    fi
}

BIN_DIR=$(target "$PREFIX/sbin")
SYSTEMD_DIR=$(target "$ETC_DIR/systemd/system")
JOURNALD_DIR=$(target "$ETC_DIR/systemd/journald.conf.d")
LOGROTATE_DIR=$(target "$ETC_DIR/logrotate.d")
APT_CONF_DIR=$(target "$ETC_DIR/apt/apt.conf.d")
DAEMON_JSON=$(target "$ETC_DIR/docker/daemon.json")

if [ -n "$RESTORE_DOCKER_BACKUP" ] && [ ! -f "$RESTORE_DOCKER_BACKUP" ]; then
    echo "backup not found: $RESTORE_DOCKER_BACKUP" >&2
    exit 1
fi
if [ -n "$RESTORE_DOCKER_BACKUP" ] && [ -L "$RESTORE_DOCKER_BACKUP" ]; then
    echo "refusing to restore symlink backup: $RESTORE_DOCKER_BACKUP" >&2
    exit 1
fi
if [ -n "$RESTORE_DOCKER_BACKUP" ] && [ -L "$DAEMON_JSON" ]; then
    echo "refusing to replace symlink: $DAEMON_JSON" >&2
    exit 1
fi
if [ -n "$RESTORE_DOCKER_BACKUP" ] && [ -e "$DAEMON_JSON" ] && [ ! -f "$DAEMON_JSON" ]; then
    echo "refusing to replace non-regular file: $DAEMON_JSON" >&2
    exit 1
fi

if [ "$SYSTEMD_ACTIONS" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        run systemctl disable --now vps-docker-clean.timer
    else
        systemctl disable --now vps-docker-clean.timer || true
    fi
fi

remove_file "$BIN_DIR/vps-docker-clean"
remove_file "$SYSTEMD_DIR/vps-docker-clean.service"
remove_file "$SYSTEMD_DIR/vps-docker-clean.timer"
if [ "$SKIP_JOURNALD" -eq 0 ]; then
    remove_file "$JOURNALD_DIR/auto-cleanup-limits.conf"
fi
if [ "$SKIP_BTMP_LOGROTATE" -eq 0 ]; then
    remove_file "$LOGROTATE_DIR/auto-cleanup-btmp"
fi
if [ "$SKIP_APT_PERIODIC" -eq 0 ]; then
    remove_file "$APT_CONF_DIR/90auto-cleanup-periodic"
fi

if [ -n "$RESTORE_DOCKER_BACKUP" ]; then
    run install -d -m 0755 "$(dirname -- "$DAEMON_JSON")"
    run cp -p "$RESTORE_DOCKER_BACKUP" "$DAEMON_JSON"
else
    echo "Left Docker daemon config unchanged: $DAEMON_JSON"
fi

if [ "$DRY_RUN" -eq 0 ]; then
    echo "Removed auto-cleanup files."
fi

if [ "$SYSTEMD_ACTIONS" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    if [ "$SKIP_JOURNALD" -eq 0 ]; then
        run systemctl restart systemd-journald
    fi
fi

print_restore_next_steps

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run complete; no files were removed."
fi
