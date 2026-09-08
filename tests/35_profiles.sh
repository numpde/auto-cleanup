#!/bin/sh
# Exercise persisted policy and destructive-command boundaries through staged installs.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/require-container.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/auto-cleanup-profiles.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
stage=$scratch/stage

"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
grep -Fxq PROFILE=vps "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq OnCalendar=daily "$stage/etc/systemd/system/vps-docker-clean.timer"

mkdir -p "$scratch/bin"
ln -s "$REPO_DIR/tests/fixtures/fake-dockerd.sh" "$scratch/bin/dockerd"
if FAKE_DOCKERD_LOG="$scratch/old-docker.log" FAKE_DOCKERD_VERSION=27.5.1 \
    PATH="$scratch/bin:$PATH" "$REPO_DIR/scripts/install.sh" --root "$scratch/old" >"$scratch/out" 2>&1; then
    echo 'old Docker unexpectedly accepted' >&2; exit 1
fi
grep -q '28 or newer' "$scratch/out"
test ! -e "$scratch/old/usr"

for args in '--profile unknown' '--cache-gib 0' '--cache-gib -1' '--cache-gib 1.5'; do
    # These fixed test arguments deliberately exercise the CLI's separate words.
    if "$REPO_DIR/scripts/install.sh" --root "$scratch/invalid" $args >"$scratch/out" 2>&1; then
        echo "invalid setting accepted: $args" >&2; exit 1
    fi
    test ! -e "$scratch/invalid"
done

# A preflight read must reject special files without waiting or installing anything.
for kind in directory fifo unreadable; do
    bad_root=$scratch/override-$kind
    mkdir -p "$bad_root/etc/default"
    override=$bad_root/etc/default/vps-docker-clean
    case "$kind" in
        directory) mkdir "$override" ;;
        fifo) mkfifo "$override" ;;
        unreadable) printf '%s\n' IMAGE_UNTIL=72h > "$override"; chmod 000 "$override" ;;
    esac
    if timeout 5 "$REPO_DIR/scripts/install.sh" --root "$bad_root" >"$scratch/out" 2>&1; then
        echo "non-readable override accepted: $kind" >&2; exit 1
    fi
    grep -q 'readable regular file' "$scratch/out"
    test ! -e "$bad_root/usr"
done

# Inject a read error after the ordinary-file check, at the grep subprocess port.
cat > "$scratch/bin/grep" <<'SH'
#!/bin/sh
for arg do
    if [ "$arg" = "$FAULT_OVERRIDE" ]; then
        echo 'injected override read failure' >&2
        exit 2
    fi
done
exec /usr/bin/grep "$@"
SH
chmod 0755 "$scratch/bin/grep"
printf '%s\n' IMAGE_UNTIL=72h > "$stage/etc/default/vps-docker-clean"
if FAULT_OVERRIDE="$stage/etc/default/vps-docker-clean" PATH="$scratch/bin:$PATH" \
    "$REPO_DIR/scripts/install.sh" --root "$stage" --profile workstation >"$scratch/out" 2>&1; then
    echo 'override read failure accepted' >&2; exit 1
fi
grep -q 'Cannot inspect cleanup overrides' "$scratch/out"
grep -Fxq PROFILE=vps "$stage/etc/default/vps-docker-clean.policy"

printf '%s\n' 'IMAGE_UNTIL=72h' > "$stage/etc/default/vps-docker-clean"
"$REPO_DIR/scripts/install.sh" --root "$stage" --profile workstation --cache-gib 8 >/dev/null
grep -Fxq PROFILE=workstation "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq CACHE_GIB=8 "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq OnCalendar=weekly "$stage/etc/systemd/system/vps-docker-clean.timer"
"$REPO_DIR/scripts/install.sh" --root "$stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null
grep -Fxq PROFILE=workstation "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq CACHE_GIB=8 "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq IMAGE_UNTIL=72h "$stage/etc/default/vps-docker-clean"

python3 - "$stage/etc/docker/daemon.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path) as stream:
    data = json.load(stream)
assert data['builder']['gc'] == {
    'enabled': True,
    'policy': [{'all': True, 'reservedSpace': '0', 'maxUsedSpace': '8GB'}],
}
data['builder']['history'] = {'maxEntries': 10}
data['builder']['gc'] = {'enabled': False, 'policy': [{'keepStorage': '500GB'}]}
with open(path, 'w') as stream:
    json.dump(data, stream)
PY
if "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >/dev/null 2>&1; then
    echo 'cache policy drift unexpectedly accepted' >&2; exit 1
fi
"$REPO_DIR/scripts/install.sh" --root "$stage" --profile workstation >/dev/null
python3 - "$stage/etc/docker/daemon.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data['builder']['history'] == {'maxEntries': 10}
assert data['builder']['gc']['policy'] == [
    {'all': True, 'reservedSpace': '0', 'maxUsedSpace': '40GB'},
]
PY

# The installed command receives managed ages followed by explicit overrides.
. "$REPO_DIR/scripts/lib/policy.sh"
read_managed_policy "$stage/etc/default/vps-docker-clean.policy"
export CONTAINER_UNTIL NETWORK_UNTIL IMAGE_UNTIL
IMAGE_UNTIL=72h DOCKER_HOST=tcp://unwanted.example:2375 DOCKER_CONTEXT=unwanted \
    FAKE_DOCKER_LOG="$scratch/prune.log" DOCKER="$REPO_DIR/tests/fixtures/fake-docker.sh" \
    "$stage/usr/local/sbin/vps-docker-clean" >/dev/null
grep -Fxq 'container prune -f --filter until=168h --filter label=auto-cleanup.disposable=true' "$scratch/prune.log"
grep -Fxq 'image prune -af --filter until=72h' "$scratch/prune.log"
if grep -Eq 'volume|builder|buildx' "$scratch/prune.log"; then
    echo 'cleanup crossed its resource boundary' >&2; exit 1
fi
"$stage/usr/local/sbin/vps-docker-clean" --show-policy > "$scratch/show"
grep -Fxq IMAGE_UNTIL=336h "$scratch/show"

if IMAGE_UNTIL=0h DOCKER="$REPO_DIR/tests/fixtures/fake-docker.sh" \
    FAKE_DOCKER_LOG="$scratch/invalid-runtime.log" \
    "$stage/usr/local/sbin/vps-docker-clean" >/dev/null 2>&1; then
    echo 'invalid runtime age accepted' >&2; exit 1
fi
test ! -e "$scratch/invalid-runtime.log"

cp "$stage/etc/default/vps-docker-clean.policy" "$scratch/saved-policy"
for tail in PROFILE=vps UNKNOWN=value =; do
    cp "$scratch/saved-policy" "$stage/etc/default/vps-docker-clean.policy"
    printf '%s' "$tail" >> "$stage/etc/default/vps-docker-clean.policy"
    if "$REPO_DIR/scripts/install.sh" --root "$stage" --profile vps >"$scratch/out" 2>&1; then
        echo "unterminated invalid policy tail accepted: $tail" >&2; exit 1
    fi
    grep -q 'Cannot read' "$scratch/out"
    grep -q 'OnCalendar=weekly' "$stage/etc/systemd/system/vps-docker-clean.timer"
done
cp "$scratch/saved-policy" "$stage/etc/default/vps-docker-clean.policy"
printf '%s\n' 'BUILD_CACHE_RESERVED=2GB' > "$stage/etc/default/vps-docker-clean"
if "$REPO_DIR/scripts/install.sh" --root "$stage" --profile vps >"$scratch/out" 2>&1; then
    echo 'obsolete overrides unexpectedly accepted' >&2; exit 1
fi
grep -q 'obsolete cache overrides' "$scratch/out"
cmp "$scratch/saved-policy" "$stage/etc/default/vps-docker-clean.policy"

"$REPO_DIR/scripts/uninstall.sh" --root "$stage" >/dev/null
test ! -e "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq BUILD_CACHE_RESERVED=2GB "$stage/etc/default/vps-docker-clean"
echo 'profiles ok'
