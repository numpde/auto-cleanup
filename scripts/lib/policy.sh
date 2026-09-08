# Profile defaults and the literal managed policy format belong to the installer.
# Never source installed policy files: staged files are data, not shell programs.

# Replace policy globals from PROFILE; callers reapply saved or explicit budgets.
profile_defaults() {
    case "$PROFILE" in
        vps)
            CACHE_GIB=1
            SCHEDULE=daily
            CONTAINER_UNTIL=24h
            NETWORK_UNTIL=24h
            IMAGE_UNTIL=24h
            ;;
        workstation)
            CACHE_GIB=40
            SCHEDULE=weekly
            CONTAINER_UNTIL=168h
            NETWORK_UNTIL=168h
            IMAGE_UNTIL=336h
            ;;
        *)
            echo "Cannot select cleanup profile '$PROFILE'; use vps or workstation." >&2
            return 1
            ;;
    esac
}

validate_cache_budget() {
    case "$CACHE_GIB" in
        ''|*[!0-9]*|0*)
            echo "Cannot configure cache budget '$CACHE_GIB'; use a positive whole number of GiB without leading zeros." >&2
            return 1
            ;;
    esac
}

# Read literal settings into policy globals without evaluating shell syntax.
# Ignore those globals after failure; profile-default agreement is checked separately.
read_managed_policy() {
    policy_path=$1
    seen=' '
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *=*) key=${line%%=*}; value=${line#*=} ;;
            *) echo "Cannot read $policy_path: each setting must use KEY=value." >&2; return 1 ;;
        esac
        case "$seen" in
            *" $key "*) echo "Cannot read $policy_path: duplicate setting '$key'." >&2; return 1 ;;
        esac
        seen="$seen$key "
        case "$key" in
            PROFILE) PROFILE=$value ;;
            CACHE_GIB) CACHE_GIB=$value ;;
            SCHEDULE) SCHEDULE=$value ;;
            CONTAINER_UNTIL) CONTAINER_UNTIL=$value ;;
            NETWORK_UNTIL) NETWORK_UNTIL=$value ;;
            IMAGE_UNTIL) IMAGE_UNTIL=$value ;;
            *) echo "Cannot read $policy_path: unknown setting '$key'." >&2; return 1 ;;
        esac
    done < "$policy_path"
    for key in PROFILE CACHE_GIB SCHEDULE CONTAINER_UNTIL NETWORK_UNTIL IMAGE_UNTIL; do
        case "$seen" in
            *" $key "*) ;;
            *) echo "Cannot read $policy_path: missing setting '$key'." >&2; return 1 ;;
        esac
    done
    case "$PROFILE:$SCHEDULE" in
        vps:daily|workstation:weekly) ;;
        *) echo "Cannot read $policy_path: profile and schedule do not match." >&2; return 1 ;;
    esac
    validate_cache_budget || return 1
    for value in "$CONTAINER_UNTIL" "$NETWORK_UNTIL" "$IMAGE_UNTIL"; do
        case "$value" in
            *h) hours=${value%h} ;;
            *) echo "Cannot read $policy_path: age '$value' must be whole hours, such as 24h." >&2; return 1 ;;
        esac
        case "$hours" in
            ''|*[!0-9]*|0*) echo "Cannot read $policy_path: age '$value' must be positive whole hours." >&2; return 1 ;;
        esac
    done
}

print_managed_policy() {
    printf '%s\n' "PROFILE=$PROFILE" "CACHE_GIB=$CACHE_GIB" "SCHEDULE=$SCHEDULE" \
        "CONTAINER_UNTIL=$CONTAINER_UNTIL" "NETWORK_UNTIL=$NETWORK_UNTIL" "IMAGE_UNTIL=$IMAGE_UNTIL"
}

# Older engines can silently ignore maxUsedSpace, so JSON validation is insufficient.
# Without dockerd, staging and dry runs only report the target version requirement.
require_gc_capability() {
    if ! command -v dockerd >/dev/null 2>&1; then
        if [ -n "$ROOT" ] || [ "$ETC_DIR" != /etc ] || [ "${DRY_RUN:-0}" -eq 1 ]; then
            echo "Docker daemon binary unavailable; target must run Docker Engine 28+ for cache limits."
            return 0
        fi
        echo "Cannot manage Docker cache: dockerd is missing; install Docker Engine 28 or newer." >&2
        return 1
    fi
    version=$(dockerd --version) || return 1
    major=$(printf '%s\n' "$version" | sed -n 's/^Docker version \([0-9][0-9]*\)\..*/\1/p')
    if [ -z "$major" ] || [ "$major" -lt 28 ]; then
        echo "Cannot manage Docker cache with '$version'; Docker Engine 28 or newer is required." >&2
        return 1
    fi
}
