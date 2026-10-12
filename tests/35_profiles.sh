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
grep -Fxq IMAGE_PROTECTION_MODE=none "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq IMAGE_KEEP_TAGS= "$stage/etc/default/vps-docker-clean.policy"
grep -Fxq OnCalendar=daily "$stage/etc/systemd/system/vps-docker-clean.timer"

# Installer choices survive reinstall and profile changes independently of budgets.
image_stage=$scratch/images
image_policy=$image_stage/etc/default/vps-docker-clean.policy
"$REPO_DIR/scripts/install.sh" --root "$image_stage" \
    --keep-image app:latest --keep-image app:rollback >/dev/null
grep -Fxq IMAGE_PROTECTION_MODE=tags "$image_policy"
grep -Fxq 'IMAGE_KEEP_TAGS=app:latest app:rollback' "$image_policy"
"$REPO_DIR/scripts/install.sh" --root "$image_stage" --profile workstation --cache-gib 8 >/dev/null
"$REPO_DIR/scripts/install.sh" --root "$image_stage" >/dev/null
"$REPO_DIR/scripts/check.sh" --root "$image_stage" --strict >/dev/null
grep -Fxq 'IMAGE_KEEP_TAGS=app:latest app:rollback' "$image_policy"
(
    . "$REPO_DIR/scripts/lib/policy.sh"
    read_managed_policy "$image_policy"
    export CONTAINER_UNTIL NETWORK_UNTIL IMAGE_UNTIL IMAGE_PROTECTION_MODE IMAGE_KEEP_TAGS
    "$image_stage/usr/local/sbin/vps-docker-clean" --show-policy
) > "$scratch/image-show"
grep -Fxq IMAGE_PROTECTION_MODE=tags "$scratch/image-show"
grep -Fxq 'IMAGE_KEEP_TAGS=app:latest app:rollback' "$scratch/image-show"
"$REPO_DIR/scripts/install.sh" --root "$image_stage" --keep-image app:stable >/dev/null
"$REPO_DIR/scripts/install.sh" --root "$image_stage" --image-protection tags >/dev/null
grep -Fxq IMAGE_KEEP_TAGS=app:stable "$image_policy"
for mode in none inventory; do
    "$REPO_DIR/scripts/install.sh" --root "$image_stage" --image-protection "$mode" >/dev/null
    grep -Fxq "IMAGE_PROTECTION_MODE=$mode" "$image_policy"
    grep -Fxq IMAGE_KEEP_TAGS= "$image_policy"
done

# Old six-field policies retain inventory protection unless explicitly changed.
for selection in preserve none; do
    legacy=$scratch/legacy-$selection
    mkdir -p "$legacy/etc/default"
    sed '/^IMAGE_PROTECTION_MODE=/d; /^IMAGE_KEEP_TAGS=/d' \
        "$stage/etc/default/vps-docker-clean.policy" > "$legacy/etc/default/vps-docker-clean.policy"
    case "$selection" in
        preserve) "$REPO_DIR/scripts/install.sh" --root "$legacy" >/dev/null; expected=inventory ;;
        none) "$REPO_DIR/scripts/install.sh" --root "$legacy" --image-protection none >/dev/null; expected=none ;;
    esac
    grep -Fxq "IMAGE_PROTECTION_MODE=$expected" "$legacy/etc/default/vps-docker-clean.policy"
    "$REPO_DIR/scripts/check.sh" --root "$legacy" --strict >/dev/null
done
for missing in IMAGE_PROTECTION_MODE IMAGE_KEEP_TAGS; do
    partial=$scratch/partial-$missing
    mkdir -p "$partial/etc/default"
    sed "/^$missing=/d" "$image_policy" > "$partial/etc/default/vps-docker-clean.policy"
    if "$REPO_DIR/scripts/install.sh" --root "$partial" >"$scratch/out" 2>&1; then
        echo "partial image protection accepted without $missing" >&2; exit 1
    fi
    grep -q "missing setting '$missing'" "$scratch/out"
    test ! -e "$partial/usr"
done

# Explicit installer choices cannot be silently overridden by the second file.
for key in IMAGE_PROTECTION_MODE IMAGE_KEEP_TAGS; do
    image_override=$image_stage/etc/default/vps-docker-clean
    case "$key" in
        IMAGE_PROTECTION_MODE) printf '%s\n' IMAGE_PROTECTION_MODE=inventory > "$image_override" ;;
        IMAGE_KEEP_TAGS) printf '%s\n' IMAGE_KEEP_TAGS=app:latest > "$image_override" ;;
    esac
    cp "$image_override" "$scratch/image-override.saved"
    "$REPO_DIR/scripts/install.sh" --root "$image_stage" >/dev/null
    cmp "$scratch/image-override.saved" "$image_override"
    cp "$image_policy" "$scratch/image-policy.saved"
    cp "$image_stage/etc/systemd/system/vps-docker-clean.timer" "$scratch/image-timer.saved"
    if "$REPO_DIR/scripts/install.sh" --root "$image_stage" --profile vps \
        --image-protection none >"$scratch/out" 2>&1; then
        echo "installer protection override conflict accepted: $key" >&2; exit 1
    fi
    grep -Fq "$image_override assigns $key" "$scratch/out"
    cmp "$scratch/image-override.saved" "$image_override"
    cmp "$scratch/image-policy.saved" "$image_policy"
    cmp "$scratch/image-timer.saved" "$image_stage/etc/systemd/system/vps-docker-clean.timer"
done
printf '%s\n' '# IMAGE_PROTECTION_MODE=inventory' 'OTHER_IMAGE_KEEP_TAGS=app:latest' > "$image_override"
"$REPO_DIR/scripts/install.sh" --root "$image_stage" --keep-image app:stable >/dev/null
grep -Fxq IMAGE_PROTECTION_MODE=tags "$image_policy"

# Both files can be present while reversed precedence silently discards overrides.
service=$stage/etc/systemd/system/vps-docker-clean.service
cp "$service" "$scratch/service.saved"
sed -e 's|EnvironmentFile=/etc/default/vps-docker-clean.policy|EnvironmentFile=-/etc/default/vps-docker-clean|; t' \
    -e 's|EnvironmentFile=-/etc/default/vps-docker-clean$|EnvironmentFile=/etc/default/vps-docker-clean.policy|' \
    "$scratch/service.saved" > "$service"
if "$REPO_DIR/scripts/check.sh" --root "$stage" --strict >"$scratch/out" 2>&1; then
    echo 'reversed environment-file precedence accepted' >&2; exit 1
fi
grep -q 'bad.*systemd service' "$scratch/out"
cp "$scratch/service.saved" "$service"

mkdir -p "$scratch/bin"
ln -s "$REPO_DIR/tests/fixtures/fake-dockerd.sh" "$scratch/bin/dockerd"
if FAKE_DOCKERD_LOG="$scratch/old-docker.log" FAKE_DOCKERD_VERSION=27.5.1 \
    PATH="$scratch/bin:$PATH" "$REPO_DIR/scripts/install.sh" --root "$scratch/old" >"$scratch/out" 2>&1; then
    echo 'old Docker unexpectedly accepted' >&2; exit 1
fi
grep -q '28 or newer' "$scratch/out"
test ! -e "$scratch/old/usr"

for args in '--profile unknown' '--cache-gib 0' '--cache-gib -1' '--cache-gib 1.5' \
    '--cache-gib 8589934592' '--cache-gib 99999999999999999999' \
    '--image-protection unknown' '--image-protection tags' '--image-protection' \
    '--keep-image' '--keep-image app' '--image-protection none --keep-image app:latest' \
    '--keep-image app:latest --image-protection inventory'; do
    # These fixed test arguments deliberately exercise the CLI's separate words.
    if "$REPO_DIR/scripts/install.sh" --root "$scratch/invalid" $args >"$scratch/out" 2>&1; then
        echo "invalid setting accepted: $args" >&2; exit 1
    fi
    test ! -e "$scratch/invalid"
done
for tag in 'app:lat est' 'app:lat\est' 'app:lat"est' "app:lat'est" \
    "$(printf 'app:latest\nPROFILE=vps')"; do
    if "$REPO_DIR/scripts/install.sh" --root "$scratch/unsafe-tag" --keep-image "$tag" >"$scratch/out" 2>&1; then
        echo "unsafe EnvironmentFile tag accepted: $tag" >&2; exit 1
    fi
    test ! -e "$scratch/unsafe-tag"
done

# The direct merger has the same representability boundary as the installer.
for budget in 8589934591 8589934592 99999999999999999999; do
    status=0
    "$REPO_DIR/lib/merge-docker-daemon.py" \
        --daemon-json "$scratch/budget.json" \
        --policy-json "$REPO_DIR/fixtures/docker/daemon-log-policy.json" \
        --cache-gib "$budget" >"$scratch/out" 2>&1 || status=$?
    if [ "$budget" = 8589934591 ]; then
        test "$status" -eq 0
        cp "$scratch/budget.json" "$scratch/budget.saved"
    else
        test "$status" -ne 0
        grep -q '8589934591' "$scratch/out"
        cmp "$scratch/budget.saved" "$scratch/budget.json"
    fi
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

export IMAGE_PROTECTION_FILE="$scratch/protection.json"
test ! -e "$IMAGE_PROTECTION_FILE"

# The installed command receives managed ages followed by explicit overrides.
. "$REPO_DIR/scripts/lib/policy.sh"
read_managed_policy "$stage/etc/default/vps-docker-clean.policy"
export CONTAINER_UNTIL NETWORK_UNTIL IMAGE_UNTIL IMAGE_PROTECTION_MODE IMAGE_KEEP_TAGS
IMAGE_UNTIL=72h DOCKER_HOST=tcp://unwanted.example:2375 DOCKER_CONTEXT=unwanted \
    FAKE_DOCKER_LOG="$scratch/prune.log" DOCKER="$REPO_DIR/tests/fixtures/fake-docker.sh" \
    "$stage/usr/local/sbin/vps-docker-clean" >/dev/null
grep -Fxq 'container prune -f --filter until=168h --filter label=auto-cleanup.disposable=true' "$scratch/prune.log"
grep -Fxq 'image rm --no-prune sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$scratch/prune.log"
if grep -Eq 'volume|builder|buildx' "$scratch/prune.log"; then
    echo 'cleanup crossed its resource boundary' >&2; exit 1
fi
"$stage/usr/local/sbin/vps-docker-clean" --show-policy > "$scratch/show"
grep -Fxq IMAGE_UNTIL=336h "$scratch/show"
grep -Fxq IMAGE_PROTECTION_MODE=none "$scratch/show"

for argument in '' --unknown; do
    if DOCKER="$REPO_DIR/tests/fixtures/fake-docker.sh" \
        FAKE_DOCKER_LOG="$scratch/invalid-argument.log" \
        "$stage/usr/local/sbin/vps-docker-clean" "$argument" >"$scratch/out" 2>&1; then
        echo "invalid cleanup argument accepted: '$argument'" >&2; exit 1
    fi
    grep -q 'Usage:' "$scratch/out"
    test ! -e "$scratch/invalid-argument.log"
done

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
