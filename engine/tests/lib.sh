#!/bin/sh
# Shared helpers for tin's repo-run test scripts.
#
# install.sh is intentionally self-contained (it is fetched and piped to `sh`)
# and does not source this file.

# Prints the sha256 digest of a file using whichever tool is available.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# Runs "$@" with a hard timeout, returning the child's exit code.
run_bounded() {
    secs=$1
    shift
    "$@" &
    pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watcher=$!
    wait "$pid" && rc=0 || rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

host_platform() {
    case "$(uname -s)" in
        Darwin) printf darwin ;;
        Linux) printf linux ;;
        *) printf other ;;
    esac
}

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf x86_64 ;;
        aarch64|arm64) printf aarch64 ;;
        *) printf other ;;
    esac
}

# Prints PATH with any directory that contains a `zig` binary removed.
sanitize_path() {
    out=
    old_ifs=$IFS
    IFS=:
    for d in $PATH; do
        [ -n "$d" ] || continue
        [ -x "$d/zig" ] && continue
        out=${out:+$out:}$d
    done
    IFS=$old_ifs
    [ -n "$out" ] || out=/usr/bin:/bin
    printf '%s' "$out"
}
