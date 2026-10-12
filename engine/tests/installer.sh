#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

. "$HERE/lib.sh"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMPROOT="$(mktemp -d "$TMP_BASE/tin-installer-test.XXXXXX")"
cleanup_all() { rm -rf "$TMPROOT"; }
trap cleanup_all EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

ARTIFACT="tin-$(host_platform)-$(host_arch)"
REV40="0123456789abcdef0123456789abcdef01234567"

make_stub_tin() {
    cat > "$1" <<'STUB'
#!/bin/sh
if [ -n "${TIN_TEST_TIN_LOG:-}" ]; then printf '%s\n' "$*" >> "$TIN_TEST_TIN_LOG"; fi
exit 0
STUB
    chmod +x "$1"
}

SRC_REPO="$TMPROOT/repo"
make_source_repo() {
    mkdir -p "$SRC_REPO/engine/src/schemas" "$SRC_REPO/environment"
    printf 'v0.1.0\n' > "$SRC_REPO/environment/marker"
    printf 'identity:\n  name: Fixture\n' > "$SRC_REPO/tinrc.yml"
    printf 'tinrc: schema\n' > "$SRC_REPO/engine/src/schemas/tinrc.yaml"
    printf 'pub fn main() void {}\n' > "$SRC_REPO/engine/main.zig"
    git -C "$SRC_REPO" init -q
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t add -A
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t commit -q -m one
    git -C "$SRC_REPO" tag v0.1.0
    printf 'v1.2.3\n' > "$SRC_REPO/environment/marker"
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t add -A
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t commit -q -m two
    git -C "$SRC_REPO" tag v1.2.3
    printf 'unreleased\n' > "$SRC_REPO/environment/marker"
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t add -A
    git -C "$SRC_REPO" -c user.email=t@t -c user.name=t commit -q -m three
}

REL_BASE="$TMPROOT/releases"
REL_BASE_URL="https://example.invalid/releases/download"
build_package_tree() {
    local dest root
    dest="$1"
    root="$dest/$ARTIFACT"
    mkdir -p "$root/bin" "$root/engine/src/schemas" "$root/environment"
    make_stub_tin "$root/bin/tin"
}
make_release() {
    local tag rev marker dest work root
    tag="$1"; rev="$2"; marker="$3"
    dest="$REL_BASE/$tag"; mkdir -p "$dest"
    work="$TMPROOT/pkg-$tag"; rm -rf "$work"; mkdir -p "$work"
    build_package_tree "$work"
    root="$work/$ARTIFACT"
    printf '%s\n' "$rev" > "$root/.tin-revision"
    printf 'tinrc: schema\n' > "$root/engine/src/schemas/tinrc.yaml"
    printf '%s\n' "$marker" > "$root/environment/marker"
    printf 'identity:\n  name: %s\n' "$marker" > "$root/tinrc.yml"
    ( cd "$work" && tar czf "$dest/$ARTIFACT.tar.gz" "$ARTIFACT" )
    write_sidecar "$dest/$ARTIFACT.tar.gz"
}
write_sidecar() {
    local archive sha
    archive="$1"
    sha="$(sha256_of "$archive")"
    printf '%s  %s\n' "$sha" "$(basename "$archive")" > "$archive.sha256"
}

BIN_STUB="$TMPROOT/stub-bin"
make_stub_curl() {
    mkdir -p "$BIN_STUB"
    cat > "$BIN_STUB/curl" <<'STUB'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;;
        -*) : ;;
        *) url="$1" ;;
    esac
    shift
done
case "$url" in
    *"${STUB_FAIL_SUBSTR:-__never__}"*)
        if [ -n "$out" ]; then printf 'partial' > "$out"; fi
        exit 56 ;;
esac
body=""
case "$url" in
    *api.github.com*) body="${STUB_LATEST_FILE:-}" ;;
    *"/releases/download/"*) rest="${url#*/releases/download/}"; body="${STUB_RELEASES_DIR:-}/$rest" ;;
    *) exit 22 ;;
esac
if [ -z "$body" ] || [ ! -f "$body" ]; then exit 22; fi
if [ -n "$out" ]; then cp "$body" "$out"; else cat "$body"; fi
exit 0
STUB
    chmod +x "$BIN_STUB/curl"
}

BIN_ZIG="$TMPROOT/zig-bin"
make_stub_zig() {
    mkdir -p "$BIN_ZIG"
    cp "$BIN_STUB/curl" "$BIN_ZIG/curl"
    cat > "$BIN_ZIG/zig" <<'STUB'
#!/bin/sh
if [ -n "${ZIG_LOG:-}" ]; then printf 'cwd=%s args=%s\n' "$PWD" "$*" >> "$ZIG_LOG"; fi
mkdir -p zig-out/bin
cat > zig-out/bin/tin <<'INNER'
#!/bin/sh
exit 0
INNER
chmod +x zig-out/bin/tin
exit 0
STUB
    chmod +x "$BIN_ZIG/zig"
}

CUR_HOME=""; CUR_TIN=""; CUR_REPO=""; CUR_RELBASE=""; CUR_EXTRA=""
OUT=""; RC=0

reset_env() {
    CUR_HOME="$TMPROOT/home-$1"; mkdir -p "$CUR_HOME"
    CUR_TIN="$TMPROOT/tin-$1"
    CUR_REPO="$SRC_REPO"
    CUR_RELBASE="$REL_BASE_URL"
    CUR_EXTRA=""
    OUT=""; RC=0
}

run_sh() {
    path="$1"; shift
    set +e
    OUT="$(env -i \
        HOME="$CUR_HOME" \
        PATH="$path" \
        TMPDIR="$TMPROOT" \
        TIN_DIR="$CUR_TIN" \
        TIN_REPO_URL="$CUR_REPO" \
        TIN_RELEASE_BASE_URL="$CUR_RELBASE" \
        STUB_RELEASES_DIR="$REL_BASE" \
        STUB_LATEST_FILE="$TMPROOT/latest.json" \
        ZIG_LOG="$TMPROOT/zig.log" \
        TIN_TEST_TIN_LOG="$TMPROOT/tin.log" \
        ${CUR_EXTRA} \
        sh "$INSTALL_SH" "$@" 2>&1)"
    RC=$?
    set -e
}

run_stdin() {
    path="$1"; shift
    set +e
    OUT="$(env -i \
        HOME="$CUR_HOME" \
        PATH="$path" \
        TMPDIR="$TMPROOT" \
        TIN_DIR="$CUR_TIN" \
        TIN_REPO_URL="$CUR_REPO" \
        TIN_RELEASE_BASE_URL="$CUR_RELBASE" \
        sh -s -- "$@" < "$INSTALL_SH" 2>&1)"
    RC=$?
    set -e
}

expect_rc() { if [ "$RC" -eq "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, expected $1)"; printf '%s\n' "$OUT" | sed 's/^/    /'; fi; }
expect_out_has() { if printf '%s' "$OUT" | grep -qF "$1"; then ok "$2"; else bad "$2 (missing: $1)"; printf '%s\n' "$OUT" | sed 's/^/    /'; fi; }
expect_exists() { if [ -e "$1" ]; then ok "$2"; else bad "$2 (missing $1)"; fi; }
expect_missing() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2 ($1 exists)"; fi; }
expect_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1' want '$2')"; fi; }
expect_file_eq() { if [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then ok "$3"; else bad "$3 (file $1: got '$(cat "$1" 2>/dev/null)' want '$2')"; fi; }
expect_no_source_build() { if [ ! -s "$TMPROOT/zig.log" ]; then ok "$1"; else bad "$1 (source build ran)"; fi; }
expect_source_build() { if [ -s "$TMPROOT/zig.log" ]; then ok "$1"; else bad "$1 (no source build)"; fi; }

test_flag_overrides_env_to_binary() {
    reset_env flagbin
    : > "$TMPROOT/zig.log"
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    CUR_EXTRA="TIN_INSTALL_MODE=source"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 0 "explicit --from-binary overrides TIN_INSTALL_MODE=source"
    expect_file_eq "$CUR_TIN/.tin-revision" "$rev" "binary install records release revision"
    expect_file_eq "$CUR_TIN/environment/marker" "v1.2.3" "binary install uses release runtime"
    expect_no_source_build "no source build when binary was requested"
}

test_flag_overrides_env_to_source() {
    reset_env flagsrc
    : > "$TMPROOT/zig.log"
    CUR_EXTRA="TIN_INSTALL_MODE=binary"
    run_sh "$PATH_ZIG" --from-source
    expect_rc 0 "explicit --from-source overrides TIN_INSTALL_MODE=binary"
    expect_source_build "source build ran when source was requested"
}

test_contradictory_flags() {
    reset_env conflict
    run_sh "$PATH_NOZIG" --from-source --from-binary
    expect_rc 1 "contradictory flags fail"
    expect_out_has "conflicting flags" "contradictory flags report a clear error"
}

test_contradictory_env() {
    reset_env conflictenv
    CUR_EXTRA="TIN_FROM_SOURCE=1 TIN_FROM_BINARY=1"
    run_sh "$PATH_NOZIG"
    expect_rc 1 "contradictory env forces fail"
    expect_out_has "conflicting environment" "contradictory env reports a clear error"
}

test_invalid_mode_env() {
    reset_env badmode
    CUR_EXTRA="TIN_INSTALL_MODE=bogus"
    run_sh "$PATH_NOZIG"
    expect_rc 1 "invalid mode fails"
    expect_out_has "invalid mode" "invalid mode reports a clear error"
}

test_unknown_flag() {
    reset_env unknown
    run_sh "$PATH_NOZIG" --bogus
    expect_rc 1 "unknown flag is rejected"
    expect_out_has "unknown argument" "unknown flag reports a clear error"
}

test_version_needs_value() {
    reset_env noverval
    run_sh "$PATH_NOZIG" --version
    expect_rc 1 "--version without a tag fails"
    expect_out_has "requires a tag" "--version without a tag reports a clear error"
}

test_invalid_versions() {
    reset_env badver
    run_sh "$PATH_NOZIG" --version ../evil
    expect_rc 1 "version with parent path is rejected"
    expect_out_has "invalid version" "invalid version reports a clear error"
    reset_env badver2
    run_sh "$PATH_NOZIG" --version=-oops
    expect_rc 1 "version starting with dash is rejected"
}

test_help() {
    reset_env help
    run_sh "$PATH_NOZIG" --help
    expect_rc 0 "--help exits zero"
    expect_out_has "Usage: install.sh" "--help prints usage"
    reset_env help2
    run_stdin "$PATH_NOZIG" --help
    expect_rc 0 "piped stdin --help exits zero"
    expect_out_has "Usage: install.sh" "piped stdin invocation runs under POSIX sh"
}

test_binary_no_zig() {
    reset_env binary
    : > "$TMPROOT/tin.log"
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 0 "binary install succeeds without zig"
    expect_exists "$CUR_TIN/bin/tin" "binary is installed"
    expect_exists "$CUR_TIN/engine/src/schemas/tinrc.yaml" "runtime schemas are installed"
    expect_exists "$CUR_TIN/environment/marker" "runtime environment is installed"
    expect_exists "$CUR_TIN/tinrc.yml" "shared default tinrc.yml is installed"
    expect_file_eq "$CUR_TIN/.tin-revision" "$rev" "installed revision is recorded"
    if grep -qx 'install' "$TMPROOT/tin.log" 2>/dev/null; then bad "installer must not run 'tin install'"; else ok "installer did not run 'tin install'"; fi
}

test_latest_api() {
    reset_env latest
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    run_sh "$PATH_NOZIG"
    expect_rc 0 "auto mode resolves latest from a stubbed API"
    expect_file_eq "$CUR_TIN/environment/marker" "v1.2.3" "latest resolution installed the released runtime"
}

test_checksum_mismatch_preserves() {
    reset_env checksum
    : > "$TMPROOT/zig.log"
    make_release v0.9.6 "$REV40" "bad"
    printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACT.tar.gz" > "$REL_BASE/v0.9.6/$ARTIFACT.tar.gz.sha256"
    mkdir -p "$CUR_TIN/bin" "$CUR_TIN/environment"
    make_stub_tin "$CUR_TIN/bin/tin"
    printf 'OLD-REV\n' > "$CUR_TIN/.tin-revision"
    printf 'OLD\n' > "$CUR_TIN/environment/marker"
    run_sh "$PATH_ZIG" --version v0.9.6
    expect_rc 1 "checksum mismatch fails"
    expect_out_has "checksum mismatch" "checksum mismatch is reported"
    expect_file_eq "$CUR_TIN/.tin-revision" "OLD-REV" "prior revision preserved on checksum failure"
    expect_file_eq "$CUR_TIN/environment/marker" "OLD" "prior runtime preserved on checksum failure"
    expect_no_source_build "checksum mismatch never falls back to source"
}

test_corrupt_archive_no_fallback() {
    reset_env corrupt
    : > "$TMPROOT/zig.log"
    make_release v0.9.5 "$REV40" "bad"
    head -c 128 /dev/urandom > "$REL_BASE/v0.9.5/$ARTIFACT.tar.gz"
    write_sidecar "$REL_BASE/v0.9.5/$ARTIFACT.tar.gz"
    run_sh "$PATH_ZIG" --version v0.9.5
    expect_rc 1 "corrupt archive fails"
    expect_out_has "not a readable tar.gz" "corrupt archive is reported"
    expect_no_source_build "corrupt archive never falls back to source"
    expect_missing "$CUR_TIN/.tin-revision" "nothing installed after corrupt archive"
}

test_invalid_metadata_no_fallback() {
    reset_env meta
    : > "$TMPROOT/zig.log"
    make_release v0.9.4 "shortrevision" "bad"
    run_sh "$PATH_ZIG" --version v0.9.4
    expect_rc 1 "invalid .tin-revision fails"
    expect_out_has "commit hash" "invalid .tin-revision is reported"
    expect_no_source_build "invalid metadata never falls back to source"
}

test_old_package_layout_rejected() {
    reset_env oldpkg
    dest="$REL_BASE/v0.9.3"; mkdir -p "$dest"
    work="$TMPROOT/old-$ARTIFACT"; rm -rf "$work"; mkdir -p "$work"
    make_stub_tin "$work/$ARTIFACT"
    ( cd "$work" && tar czf "$dest/$ARTIFACT.tar.gz" "$ARTIFACT" )
    write_sidecar "$dest/$ARTIFACT.tar.gz"
    run_sh "$PATH_NOZIG" --from-binary --version v0.9.3
    expect_rc 1 "flat old-format archive is rejected"
    expect_out_has "older release format" "old-format archive is reported clearly"
}

test_missing_sidecar_rejected() {
    reset_env noside
    dest="$REL_BASE/v0.9.2"; mkdir -p "$dest"
    work="$TMPROOT/noside"; rm -rf "$work"; mkdir -p "$work"
    build_package_tree "$work"
    root="$work/$ARTIFACT"
    printf '%s\n' "$REV40" > "$root/.tin-revision"
    printf 'x\n' > "$root/engine/src/schemas/tinrc.yaml"
    printf 'x\n' > "$root/environment/marker"
    printf 'identity:\n' > "$root/tinrc.yml"
    ( cd "$work" && tar czf "$dest/$ARTIFACT.tar.gz" "$ARTIFACT" )
    run_sh "$PATH_NOZIG" --from-binary --version v0.9.2
    expect_rc 1 "package without a checksum sidecar is rejected"
    expect_out_has "unverified package" "missing sidecar is reported clearly"
}

test_unsafe_symlink_rejected() {
    reset_env symlink
    dest="$REL_BASE/v0.9.1"; mkdir -p "$dest"
    work="$TMPROOT/symlink"; rm -rf "$work"; mkdir -p "$work"
    build_package_tree "$work"
    root="$work/$ARTIFACT"
    printf '%s\n' "$REV40" > "$root/.tin-revision"
    printf 'x\n' > "$root/engine/src/schemas/tinrc.yaml"
    printf 'x\n' > "$root/environment/marker"
    printf 'identity:\n' > "$root/tinrc.yml"
    ln -s "../../../../etc/passwd" "$root/engine/src/schemas/escape"
    ( cd "$work" && tar czf "$dest/$ARTIFACT.tar.gz" "$ARTIFACT" )
    write_sidecar "$dest/$ARTIFACT.tar.gz"
    run_sh "$PATH_NOZIG" --from-binary --version v0.9.1
    expect_rc 1 "escaping symlink is rejected"
    expect_out_has "symlink" "escaping symlink is reported"
}

test_outside_root_rejected() {
    reset_env outside
    dest="$REL_BASE/v0.9.0"; mkdir -p "$dest"
    work="$TMPROOT/outside"; rm -rf "$work"; mkdir -p "$work/other"
    printf 'x\n' > "$work/other/file"
    ( cd "$work" && tar czf "$dest/$ARTIFACT.tar.gz" other )
    write_sidecar "$dest/$ARTIFACT.tar.gz"
    run_sh "$PATH_NOZIG" --from-binary --version v0.9.0
    expect_rc 1 "archive with foreign root is rejected"
    expect_out_has "outside" "foreign root is reported"
}

test_interrupted_download() {
    reset_env interrupted
    CUR_EXTRA="STUB_FAIL_SUBSTR=$ARTIFACT.tar.gz"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 1 "interrupted download fails in binary mode"
    expect_out_has "no prebuilt binary available" "interrupted download reports unavailability"
}

test_unavailable_asset_fallback_same_version() {
    reset_env fallback
    : > "$TMPROOT/zig.log"
    rev01="$(git -C "$SRC_REPO" rev-parse v0.1.0)"
    run_sh "$PATH_ZIG" --version v0.1.0
    expect_rc 0 "missing asset falls back to source in auto mode"
    expect_source_build "fallback built from source"
    expect_file_eq "$CUR_TIN/.tin-revision" "$rev01" "fallback uses the same resolved version"
    expect_file_eq "$CUR_TIN/environment/marker" "v0.1.0" "fallback did not use the default branch"
}

test_binary_unavailable_fails() {
    reset_env binunavail
    run_sh "$PATH_NOZIG" --from-binary --version v0.1.0
    expect_rc 1 "binary mode fails when the asset is unavailable"
    expect_out_has "no prebuilt binary available" "binary mode reports unavailability"
}

test_source_pinned() {
    reset_env srcpin
    : > "$TMPROOT/zig.log"
    mkdir -p "$CUR_TIN"
    git -C "$CUR_TIN" init -q
    printf 'keep\n' > "$CUR_TIN/marker"
    git -C "$CUR_TIN" -c user.email=t@t -c user.name=t add -A
    git -C "$CUR_TIN" -c user.email=t@t -c user.name=t commit -q -m init
    rev01="$(git -C "$SRC_REPO" rev-parse v0.1.0)"
    run_sh "$PATH_ZIG" --from-source --version v0.1.0
    expect_rc 0 "pinned source build succeeds"
    expect_file_eq "$CUR_TIN/.tin-revision" "$rev01" "pinned source used the pinned commit"
    expect_file_eq "$CUR_TIN/environment/marker" "v0.1.0" "pinned source used the pinned runtime"
    expect_file_eq "$CUR_TIN/marker" "keep" "existing checkout contents preserved"
    if [ -z "$(git -C "$SRC_REPO" status --porcelain)" ]; then ok "source repo not modified"; else bad "source repo was modified"; fi
}

test_source_unpinned_existing_checkout() {
    reset_env unpinned
    : > "$TMPROOT/zig.log"
    git clone -q "$SRC_REPO" "$CUR_TIN"
    head="$(git -C "$SRC_REPO" rev-parse HEAD)"
    run_sh "$PATH_ZIG" --from-source
    expect_rc 0 "unpinned source build succeeds"
    expect_file_eq "$CUR_TIN/.tin-revision" "$head" "unpinned source recorded the checkout commit"
    expect_file_eq "$CUR_TIN/environment/marker" "unreleased" "unpinned source used the checkout runtime"
    if grep -qF "cwd=$CUR_TIN/engine" "$TMPROOT/zig.log" && grep -qF "args=build install-tin -Doptimize=ReleaseSafe" "$TMPROOT/zig.log"; then ok "existing checkout built with install-tin -Doptimize=ReleaseSafe"; else bad "unexpected zig invocation: $(cat "$TMPROOT/zig.log")"; fi
}

test_dirty_checkout_refused() {
    reset_env dirty
    git clone -q "$SRC_REPO" "$CUR_TIN"
    printf 'edited\n' >> "$CUR_TIN/tinrc.yml"
    before="$(cat "$CUR_TIN/tinrc.yml")"
    run_sh "$PATH_ZIG" --from-source
    expect_rc 1 "dirty checkout is refused"
    expect_out_has "dirty checkout" "dirty checkout is reported"
    expect_file_eq "$CUR_TIN/tinrc.yml" "$before" "dirty file left untouched"
    expect_missing "$CUR_TIN/.tin-revision" "no install happened on dirty refusal"
    if ls "$CUR_TIN"/.tin-install-* >/dev/null 2>&1; then bad "staging directory left behind"; else ok "no staging directory left behind"; fi
}

test_reinstall() {
    reset_env reinstall
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 0 "first install succeeds"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 0 "reinstall over an existing install succeeds"
    expect_file_eq "$CUR_TIN/environment/marker" "v1.2.3" "reinstall replaced the runtime"
    expect_exists "$CUR_TIN/bin/tin" "reinstall kept the binary"
}

test_personal_config_preserved() {
    reset_env personal
    mkdir -p "$CUR_HOME/.config/tin/artifacts"
    printf 'personal: yes\n' > "$CUR_HOME/.config/tin/tinrc.yml"
    printf 'artifact\n' > "$CUR_HOME/.config/tin/artifacts/keep.txt"
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 0 "install succeeds with a personal override present"
    expect_file_eq "$CUR_HOME/.config/tin/tinrc.yml" "personal: yes" "personal tinrc.yml preserved"
    expect_file_eq "$CUR_HOME/.config/tin/artifacts/keep.txt" "artifact" "personal artifacts preserved"
}

test_prior_install_preserved_on_promote_failure() {
    reset_env promote
    rev="$(git -C "$SRC_REPO" rev-parse v1.2.3)"
    make_release v1.2.3 "$rev" "v1.2.3"
    mkdir -p "$CUR_TIN"
    printf 'blocker\n' > "$CUR_TIN/bin"
    run_sh "$PATH_NOZIG" --from-binary --version v1.2.3
    expect_rc 1 "promotion failure is reported"
    expect_file_eq "$CUR_TIN/bin" "blocker" "prior state preserved on promotion failure"
    expect_missing "$CUR_TIN/.tin-revision" "no partial install left on promotion failure"
}

test_blocked_binary_preserved() {
    reset_env blocked
    make_release v0.9.6 "$REV40" "bad"
    printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACT.tar.gz" > "$REL_BASE/v0.9.6/$ARTIFACT.tar.gz.sha256"
    mkdir -p "$CUR_TIN/bin"
    make_stub_tin "$CUR_TIN/bin/tin"
    printf 'KEEP\n' > "$CUR_TIN/.tin-revision"
    run_sh "$PATH_NOZIG" --from-binary --version v0.9.6
    expect_rc 1 "blocked install fails"
    expect_file_eq "$CUR_TIN/.tin-revision" "KEEP" "blocked install preserved the working binary"
    expect_exists "$CUR_TIN/bin/tin" "blocked install kept the existing binary"
}

main() {
    printf '[tin] installer tests\n'
    if [ ! -f "$INSTALL_SH" ]; then
        printf 'install.sh not found at %s\n' "$INSTALL_SH" >&2
        exit 2
    fi
    make_stub_curl
    make_stub_zig
    make_source_repo
    printf '{"tag_name":"v1.2.3"}\n' > "$TMPROOT/latest.json"
    PATH_NOZIG="$BIN_STUB:/usr/bin:/bin"
    PATH_ZIG="$BIN_ZIG:/usr/bin:/bin"

    test_flag_overrides_env_to_binary
    test_flag_overrides_env_to_source
    test_contradictory_flags
    test_contradictory_env
    test_invalid_mode_env
    test_unknown_flag
    test_version_needs_value
    test_invalid_versions
    test_help
    test_binary_no_zig
    test_latest_api
    test_checksum_mismatch_preserves
    test_corrupt_archive_no_fallback
    test_invalid_metadata_no_fallback
    test_old_package_layout_rejected
    test_missing_sidecar_rejected
    test_unsafe_symlink_rejected
    test_outside_root_rejected
    test_interrupted_download
    test_unavailable_asset_fallback_same_version
    test_binary_unavailable_fails
    test_source_pinned
    test_source_unpinned_existing_checkout
    test_dirty_checkout_refused
    test_reinstall
    test_personal_config_preserved
    test_prior_install_preserved_on_promote_failure
    test_blocked_binary_preserved

    printf '\n[tin] Results: %d passed, %d failed\n' "$PASS" "$FAIL"
    if [ "$FAIL" -gt 0 ]; then exit 1; fi
}

main "$@"
