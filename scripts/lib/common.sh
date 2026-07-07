# Shared helpers for repo entrypoint scripts; source this file, do not execute it.

trim_trailing_slashes() {
    value=$1
    while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
        value=${value%/}
    done
    printf '%s\n' "$value"
}

validate_path() {
    name=$1
    value=$2
    case "$value" in
        /*) ;;
        *)
            echo "$name must be an absolute path: $value" >&2
            exit 2
            ;;
    esac
    case "$value" in
        //*)
            echo "$name must not start with //: $value" >&2
            exit 2
            ;;
    esac
    if [ "$value" = "/" ]; then
        echo "$name must not be /" >&2
        exit 2
    fi
    case "$value" in
        */./*|*/../*|*/.|*/..)
            echo "$name must not contain '.' or '..' path components: $value" >&2
            exit 2
            ;;
    esac
    if printf '%s\n' "$value" | grep -q '[[:space:]&|\\%#;]'; then
        echo "$name must not contain whitespace, '&', '|', '\\', '%', '#', or ';': $value" >&2
        exit 2
    fi
    case "$value" in
        *'$'*|*\"*|*"'"*|*'`'*)
            echo "$name must not contain '$', quotes, or backticks: $value" >&2
            exit 2
            ;;
    esac
}

assert_parent_path_safe() {
    root=$1
    path=$2

    if [ -n "$root" ]; then
        case "$path" in
            "$root"/*) ;;
            *)
                echo "refusing path outside staged root: $path" >&2
                exit 1
                ;;
        esac

        if [ -L "$root" ]; then
            echo "refusing staged root symlink: $root" >&2
            exit 1
        fi
    fi

    parent=$(dirname -- "$path")
    case "$parent" in
        /) return 0 ;;
    esac
    rel=${parent#/}
    current=
    old_ifs=$IFS
    IFS=/
    for component in $rel; do
        current=$current/$component
        if [ -L "$current" ]; then
            IFS=$old_ifs
            echo "refusing path through symlink directory: $current" >&2
            exit 1
        fi
    done
    IFS=$old_ifs
}

has_existing_apt_cleanup_policy() {
    dir=$1
    apt_cleanup_re='^[[:space:]]*APT::Periodic::(AutocleanInterval|CleanInterval)'
    apt_cleanup_re=$apt_cleanup_re'[[:space:]]+"([1-9][0-9]*|always)"[[:space:]]*;'
    [ -d "$dir" ] || return 1
    grep -ERqs "$apt_cleanup_re" "$dir" 2>/dev/null
}

has_existing_btmp_policy() {
    dir=$1
    [ -d "$dir" ] || return 1
    for file in "$dir"/*; do
        [ -f "$file" ] || continue
        if awk '
            /^[[:space:]]*[^#{}]*\/var\/log\/btmp($|[[:space:]{}])/ { in_btmp = 1; next }
            in_btmp && /^[[:space:]]*\}/ { in_btmp = 0; next }
            in_btmp && /^[[:space:]]*maxsize 50M$/ { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}
