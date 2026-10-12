#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-integrity.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
stage=$scratch/stage
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
while IFS='|' read -r path setting message; do
    cp "$stage/$path" "$scratch/original"
    printf '%s\n' "$setting" >> "$stage/$path"
    if "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >"$scratch/out" 2>&1; then
        echo "conflicting managed directive accepted: $path $setting" >&2; exit 1
    fi
    grep -q "$message" "$scratch/out"
    cp "$scratch/original" "$stage/$path"
done <<'EOF'
etc/systemd/system/vps-docker-clean.timer|OnCalendar=hourly|bad.*systemd timer policy
etc/systemd/system/vps-docker-clean.service|ExecStart=/bin/true|bad.*systemd service policy
etc/systemd/journald.conf.d/auto-cleanup-limits.conf|SystemMaxUse=9G|bad.*journald limit policy
etc/apt/apt.conf.d/90auto-cleanup-periodic|APT::Periodic::CleanInterval "0";|bad.*APT periodic cleanup policy
etc/logrotate.d/auto-cleanup-btmp|/var/log/btmp { monthly }|bad.*btmp logrotate policy
EOF
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
# A failed renderer must not certify an empty unit as matching empty output.
mkdir "$scratch/bin"
cat > "$scratch/bin/sed" <<'EOF'
#!/bin/sh
for arg do
    case "$arg" in
        */fixtures/systemd/vps-docker-clean.service) echo 'injected rendering failure' >&2; exit 42 ;;
    esac
done
exec /usr/bin/sed "$@"
EOF
chmod 0755 "$scratch/bin/sed"
cp "$stage/etc/systemd/system/vps-docker-clean.service" "$scratch/service"
: > "$stage/etc/systemd/system/vps-docker-clean.service"
if PATH="$scratch/bin:$PATH" "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >"$scratch/out" 2>&1; then
    echo 'failed renderer accepted empty service' >&2; exit 1
fi
grep -q 'bad.*systemd service policy' "$scratch/out"
cp "$scratch/service" "$stage/etc/systemd/system/vps-docker-clean.service"
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
echo 'managed policy integrity ok'
