#!/bin/sh
# Inspect installed policy as data; never execute a staged cleanup program.
set -eu

usage() {
    cat <<'EOF'
Usage: check.sh [options]

Options:
  --root DIR      Check a staged root instead of the real filesystem
  --prefix DIR    Prefix for installed executables (default: /usr/local)
  --etc-dir DIR   Configuration root (default: /etc)
  --skip-docker-config
                  Do not require Docker daemon config
  --skip-journald
                  Do not require journald limits policy
  --skip-btmp-logrotate
                  Do not require btmp logrotate policy
  --skip-apt-periodic
                  Do not require APT periodic cleanup policy
  --strict        Exit nonzero when expected files are missing or invalid
  -h, --help      Show this help
EOF
}

ROOT=
PREFIX=/usr/local
ETC_DIR=/etc
STRICT=0
FAILED=0
SKIP_DOCKER_CONFIG=0
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
        --strict)
            STRICT=1
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
if [ ! -f "$SCRIPT_DIR/lib/policy.sh" ]; then
    echo "missing support file: $SCRIPT_DIR/lib/policy.sh" >&2
    exit 1
fi
. "$SCRIPT_DIR/lib/policy.sh"

PREFIX=$(trim_trailing_slashes "$PREFIX")
ETC_DIR=$(trim_trailing_slashes "$ETC_DIR")
if [ -n "$ROOT" ]; then
    ROOT=$(trim_trailing_slashes "$ROOT")
fi

target() {
    printf '%s%s\n' "$ROOT" "$1"
}

check_file() {
    path=$1
    if [ -L "$path" ]; then
        echo "bad     $path is a symlink"
        FAILED=1
    elif [ -e "$path" ] && [ ! -f "$path" ]; then
        echo "bad     $path is not a regular file"
        FAILED=1
    elif [ -e "$path" ]; then
        echo "ok      $path"
    else
        echo "missing $path"
        FAILED=1
    fi
}

check_executable() {
    path=$1
    if [ -L "$path" ]; then
        echo "bad     $path is a symlink"
        FAILED=1
    elif [ -e "$path" ] && [ ! -f "$path" ]; then
        echo "bad     $path is not a regular file"
        FAILED=1
    elif [ -x "$path" ]; then
        echo "ok      $path"
    elif [ -e "$path" ]; then
        echo "bad     $path is not executable"
        FAILED=1
    else
        echo "missing $path"
        FAILED=1
    fi
}

is_plain_file() {
    path=$1
    [ -f "$path" ] && [ ! -L "$path" ]
}

check_dockerd_config() {
    config_path=$1
    if command -v dockerd >/dev/null 2>&1; then
        if dockerd --validate --config-file "$config_path" >/dev/null 2>&1; then
            echo "ok      Docker daemon config validates with dockerd"
        else
            echo "bad     Docker daemon config rejected by dockerd"
            FAILED=1
        fi
    else
        echo "info    dockerd not found; skipped Docker daemon startup validation"
    fi
}

validate_path --prefix "$PREFIX"
validate_path --etc-dir "$ETC_DIR"
if [ -n "$ROOT" ]; then
    validate_path --root "$ROOT"
fi

check_executable "$(target "$PREFIX/sbin/vps-docker-clean")"
if ! command -v python3 >/dev/null 2>&1; then
    echo "missing python3 for the installed Docker retention executor"
    FAILED=1
fi
managed_policy=$(target "$ETC_DIR/default/vps-docker-clean.policy")
check_file "$managed_policy"
POLICY_VALID=0
if is_plain_file "$managed_policy" && read_managed_policy "$managed_policy"; then
    saved_cache=$CACHE_GIB
    profile_defaults
    CACHE_GIB=$saved_cache
    if [ "$(print_managed_policy)" = "$(cat "$managed_policy")" ]; then
        POLICY_VALID=1
        echo "Managed defaults (not live daemon state or operator age overrides):"
        print_managed_policy
    else
        echo "bad     Managed policy differs from profile defaults; reinstall to regenerate it."
        FAILED=1
    fi
else
    FAILED=1
fi
override_file=$(target "$ETC_DIR/default/vps-docker-clean")
if [ -e "$override_file" ]; then
    echo "info    Operator overrides at $override_file may change runtime ages; systemd reads this file."
fi
service_file=$(target "$ETC_DIR/systemd/system/vps-docker-clean.service")
timer_file=$(target "$ETC_DIR/systemd/system/vps-docker-clean.timer")
check_file "$service_file"
if is_plain_file "$service_file"; then
    # Systemd applies later environment files last; presence alone cannot prove precedence.
    expected_environment_files=$(printf '%s\n' \
        "EnvironmentFile=$ETC_DIR/default/vps-docker-clean.policy" \
        "EnvironmentFile=-$ETC_DIR/default/vps-docker-clean")
    if grep -Fxq "ConditionFileIsExecutable=$PREFIX/sbin/vps-docker-clean" "$service_file" &&
        grep -Fxq "Type=oneshot" "$service_file" &&
        [ "$(sed -n '/^EnvironmentFile=/p' "$service_file")" = "$expected_environment_files" ] &&
        grep -Fxq "ExecStart=$PREFIX/sbin/vps-docker-clean" "$service_file" &&
        grep -Fxq "Nice=10" "$service_file" &&
        grep -Fxq "IOSchedulingClass=idle" "$service_file" &&
        grep -Fxq "TimeoutStartSec=30min" "$service_file"; then
        echo "ok      systemd service policy"
    else
        echo "bad     systemd service policy"
        FAILED=1
    fi
fi
check_file "$timer_file"
if is_plain_file "$timer_file"; then
    if [ "$POLICY_VALID" -eq 1 ] && grep -Fxq "OnCalendar=$SCHEDULE" "$timer_file" &&
        grep -q '^Persistent=true$' "$timer_file" &&
        grep -q '^RandomizedDelaySec=1h$' "$timer_file" &&
        grep -q '^AccuracySec=1h$' "$timer_file"; then
        echo "ok      systemd timer policy"
    else
        echo "bad     systemd timer policy"
        FAILED=1
    fi
fi
if [ "$SKIP_JOURNALD" -eq 0 ]; then
    journald_conf=$(target "$ETC_DIR/systemd/journald.conf.d/auto-cleanup-limits.conf")
    check_file "$journald_conf"
    if is_plain_file "$journald_conf"; then
        if grep -q '^\[Journal\]$' "$journald_conf" &&
            grep -q '^SystemMaxUse=300M$' "$journald_conf" &&
            grep -q '^SystemKeepFree=1G$' "$journald_conf" &&
            grep -q '^MaxRetentionSec=14day$' "$journald_conf"; then
            echo "ok      journald limit policy"
        else
            echo "bad     journald limit policy"
            FAILED=1
        fi
    fi
fi
if [ "$SKIP_APT_PERIODIC" -eq 0 ]; then
    apt_periodic=$(target "$ETC_DIR/apt/apt.conf.d/90auto-cleanup-periodic")
    if is_plain_file "$apt_periodic"; then
        echo "ok      $apt_periodic"
        if grep -q 'APT::Periodic::Update-Package-Lists "1";' "$apt_periodic" &&
            grep -q 'APT::Periodic::AutocleanInterval "7";' "$apt_periodic" &&
            grep -q 'APT::Periodic::CleanInterval "30";' "$apt_periodic"; then
            echo "ok      APT periodic cleanup policy"
        else
            echo "bad     APT periodic cleanup policy"
            FAILED=1
        fi
    elif [ -e "$apt_periodic" ] || [ -L "$apt_periodic" ]; then
        check_file "$apt_periodic"
    elif has_existing_apt_cleanup_policy "$(target "$ETC_DIR/apt/apt.conf.d")"; then
        echo "ok      existing APT cleanup settings found"
    else
        echo "missing APT periodic cleanup settings"
        FAILED=1
    fi
fi
if [ "$SKIP_DOCKER_CONFIG" -eq 0 ]; then
    daemon_json=$(target "$ETC_DIR/docker/daemon.json")
    check_file "$daemon_json"
    if is_plain_file "$daemon_json"; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo "missing python3 for Docker daemon policy validation"
            FAILED=1
        else
            if [ "$POLICY_VALID" -eq 1 ] && require_gc_capability &&
                python3 "$REPO_DIR/lib/merge-docker-daemon.py" \
                    --daemon-json "$daemon_json" \
                    --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
                    --cache-gib "$CACHE_GIB" --check
            then
                echo "ok      Docker daemon logging and cache policy on disk"
            else
                echo "bad     Docker daemon logging or cache policy"
                FAILED=1
            fi
            check_dockerd_config "$daemon_json"
        fi
    fi
fi

if [ "$SKIP_BTMP_LOGROTATE" -eq 0 ]; then
    btmp_logrotate=$(target "$ETC_DIR/logrotate.d/auto-cleanup-btmp")
    if is_plain_file "$btmp_logrotate"; then
        echo "ok      $btmp_logrotate"
        if grep -q '^/var/log/btmp {' "$btmp_logrotate" &&
            grep -q '^[[:space:]]*maxsize 50M$' "$btmp_logrotate" &&
            grep -q '^[[:space:]]*rotate 1$' "$btmp_logrotate" &&
            grep -q '^[[:space:]]*create 0660 root utmp$' "$btmp_logrotate"; then
            echo "ok      btmp logrotate policy"
        else
            echo "bad     btmp logrotate policy"
            FAILED=1
        fi
    elif [ -e "$btmp_logrotate" ] || [ -L "$btmp_logrotate" ]; then
        check_file "$btmp_logrotate"
    elif has_existing_btmp_policy "$(target "$ETC_DIR/logrotate.d")"; then
        echo "ok      existing size-based btmp logrotate stanza found"
    else
        echo "missing btmp logrotate stanza"
        FAILED=1
    fi
fi

if [ -z "$ROOT" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        timer_enabled=$(systemctl is-enabled vps-docker-clean.timer 2>/dev/null || true)
        timer_active=$(systemctl is-active vps-docker-clean.timer 2>/dev/null || true)
        if [ -n "$timer_enabled" ]; then
            echo "timer enabled: $timer_enabled"
        fi
        if [ -n "$timer_active" ]; then
            echo "timer active:  $timer_active"
        fi
    fi
    if command -v docker >/dev/null 2>&1; then
        logging_driver=$(
            unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
            docker --host unix:///var/run/docker.sock info --format '{{.LoggingDriver}}' 2>/dev/null || true
        )
        if [ -n "$logging_driver" ]; then
            echo "Local Docker logging driver: $logging_driver"
        fi
    fi
    echo "root filesystem:"
    df -h / 2>/dev/null || true
fi

if [ "$STRICT" -eq 1 ] && [ "$FAILED" -ne 0 ]; then
    exit 1
fi
