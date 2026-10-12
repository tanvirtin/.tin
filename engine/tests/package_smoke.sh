#!/bin/sh
set -eu

SH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SH_DIR/lib.sh"

die() {
    echo "[smoke] ERROR: $*" >&2
    exit 2
}

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "[smoke] PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "[smoke] FAIL: $1" >&2; }

if [ "$#" -ne 2 ]; then
    echo "Usage: package_smoke.sh <archive> <checksum>" >&2
    exit 2
fi

ARCHIVE=$1
CHECKSUM=$2

[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ -f "$CHECKSUM" ] || die "checksum file not found: $CHECKSUM"

ARCHIVE_BASE=${ARCHIVE##*/}
case "$ARCHIVE_BASE" in
    *.tar.gz) ROOT=${ARCHIVE_BASE%.tar.gz} ;;
    *) die "archive must end in .tar.gz: $ARCHIVE_BASE" ;;
esac

case "$ROOT" in
    tin-darwin-aarch64|tin-darwin-x86_64|tin-linux-aarch64|tin-linux-x86_64) ;;
    *) die "unexpected artifact name: $ROOT" ;;
esac

[ "${CHECKSUM##*/}" = "$ARCHIVE_BASE.sha256" ] ||
    die "checksum file must be named $ARCHIVE_BASE.sha256"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tin-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

EXPECTED_SUM=$(awk 'NR==1 {print $1}' "$CHECKSUM")
SIDE_NAME=$(awk 'NR==1 {print $2}' "$CHECKSUM")
printf '%s' "$EXPECTED_SUM" | grep -Eq '^[0-9a-fA-F]{64}$' ||
    die "checksum is not a sha256 hex digest: $EXPECTED_SUM"
[ "$SIDE_NAME" = "$ARCHIVE_BASE" ] ||
    die "checksum names '$SIDE_NAME', expected '$ARCHIVE_BASE'"

CHECKSUM_OK=0
ACTUAL_SUM=$(sha256_of "$ARCHIVE")
if [ "$ACTUAL_SUM" = "$EXPECTED_SUM" ]; then
    CHECKSUM_OK=1
    pass "checksum matches $ARCHIVE_BASE"
else
    fail "checksum mismatch for $ARCHIVE_BASE"
fi

inspect_archive() {
    tar -tzf "$ARCHIVE" > "$WORK/list"
    tar -tvzf "$ARCHIVE" > "$WORK/verbose"

    have_bin=0
    have_rev=0
    have_tinrc=0
    have_schemas=0
    have_env=0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "/$entry/" in
            */../*) fail "archive member has a traversal segment: $entry"; continue ;;
        esac
        case "$entry" in
            /*) fail "archive member is absolute: $entry"; continue ;;
        esac
        case "$entry" in
            "$ROOT"|"$ROOT"/*) ;;
            *) fail "archive member is outside $ROOT/: $entry"; continue ;;
        esac
        inner=${entry#"$ROOT"}
        inner=${inner#/}
        [ -n "$inner" ] || continue
        case "$entry" in
            */) continue ;;
        esac
        case "$inner" in
            bin/tin) have_bin=1 ;;
            .tin-revision) have_rev=1 ;;
            tinrc.yml) have_tinrc=1 ;;
            engine/src/schemas/*) have_schemas=1 ;;
            environment/*) have_env=1 ;;
            *) fail "unexpected archive member: $entry" ;;
        esac
    done < "$WORK/list"

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        kind=$(printf '%s' "$line" | cut -c1)
        case "$kind" in
            -|d) ;;
            *) fail "unexpected archive entry type '$kind': $line" ;;
        esac
    done < "$WORK/verbose"

    [ "$have_bin" = 1 ] && pass "member bin/tin present" || fail "member bin/tin missing"
    [ "$have_rev" = 1 ] && pass "member .tin-revision present" || fail "member .tin-revision missing"
    [ "$have_tinrc" = 1 ] && pass "member tinrc.yml present" || fail "member tinrc.yml missing"
    [ "$have_schemas" = 1 ] && pass "member engine/src/schemas/ present" || fail "member engine/src/schemas/ missing"
    [ "$have_env" = 1 ] && pass "member environment/ present" || fail "member environment/ missing"
}

inspect_archive

mkdir -p "$WORK/extract"
tar -xzf "$ARCHIVE" -C "$WORK/extract"
TIN_ROOT="$WORK/extract/$ROOT"
[ -d "$TIN_ROOT" ] || die "archive did not extract $ROOT/"

if find "$TIN_ROOT" -type l | grep -q .; then
    fail "archive contains symlinks"
else
    pass "archive contains no symlinks"
fi

if [ -f "$TIN_ROOT/bin/tin" ] && [ -x "$TIN_ROOT/bin/tin" ]; then
    pass "bin/tin is executable"
else
    fail "bin/tin is missing or not executable"
fi

REVISION=
if [ -f "$TIN_ROOT/.tin-revision" ]; then
    REVISION=$(head -n1 "$TIN_ROOT/.tin-revision")
    if printf '%s' "$REVISION" | grep -Eq '^[0-9a-f]{40}$'; then
        pass ".tin-revision holds a full commit"
    else
        fail ".tin-revision is not a full commit: $REVISION"
    fi
    if [ -n "${TIN_EXPECTED_REVISION:-}" ]; then
        if [ "$REVISION" = "$TIN_EXPECTED_REVISION" ]; then
            pass ".tin-revision matches the requested revision"
        else
            fail ".tin-revision does not match the requested revision"
        fi
    fi
fi

is_neutral() {
    file=$1
    vals=$(awk '
        function value() { v=$0; sub(/^[[:space:]]+[a-z]+:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); gsub(/^"|"$/, "", v); return v }
        /^identity:[[:space:]]*$/ { inblk=1; next }
        /^[^[:space:]]/ { inblk=0 }
        inblk && /^[[:space:]]+name:/ { v=value(); if (v != "") print "name=" v }
        inblk && /^[[:space:]]+email:/ { v=value(); if (v != "") print "email=" v }
    ' "$file")
    name=$(printf '%s\n' "$vals" | sed -n 's/^name=//p')
    email=$(printf '%s\n' "$vals" | sed -n 's/^email=//p')
    lower_name=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
    case "$lower_name" in
        ""|"your name"|"your_name") ;;
        *) return 1 ;;
    esac
    case "$email" in
        ""|*@example.com|*@example.org) ;;
        *) return 1 ;;
    esac
    return 0
}

check_neutral_defaults() {
    for f in "$TIN_ROOT/tinrc.yml"; do
        [ -f "$f" ] || continue
        rel=${f#"$TIN_ROOT/"}
        if is_neutral "$f"; then
            pass "neutral default: $rel"
        else
            fail "non-neutral identity in packaged config: $rel (blocked neutral-default migration checkpoint)"
        fi
    done
}

tin() {
    HOME="$FUNC_HOME" TIN_DIR="$FUNC_ROOT" PATH="$SAFE_PATH" \
        "$FUNC_ROOT/bin/tin" "$@" </dev/null
}

functional_checks() {
    FUNC_ROOT=$1
    label=$2
    FUNC_HOME="$WORK/home-$label"
    mkdir -p "$FUNC_HOME"

    rc=0
    run_bounded 30 tin help > "$WORK/help-$label.out" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -q "Usage:" "$WORK/help-$label.out"; then
        pass "tin help ($label)"
    else
        fail "tin help ($label) [exit $rc]"
    fi

    rc=0
    run_bounded 30 tin schema list > "$WORK/schema-$label.out" 2>&1 || rc=$?
    missing=
    for s in skill rule mcp dialect tinrc recipe; do
        grep -qx "$s" "$WORK/schema-$label.out" || missing="$missing $s"
    done
    if [ "$rc" = 0 ] && [ -z "$missing" ]; then
        pass "tin schema list ($label)"
    else
        fail "tin schema list ($label) [exit $rc missing:$missing]"
    fi

    valid="$WORK/valid-skill-$label.yml"
    invalid="$WORK/invalid-skill-$label.yml"
    printf 'description: smoke skill\nsystem: |\n  do the thing\n' > "$valid"
    printf 'description: smoke skill\nunknown_field: true\n' > "$invalid"

    rc=0
    run_bounded 30 tin validate skill "$valid" > "$WORK/valid-$label.out" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
        pass "schema validation accepts a valid document ($label)"
    else
        fail "schema validation rejected a valid document ($label) [exit $rc]"
    fi

    rc=0
    run_bounded 30 tin validate skill "$invalid" > "$WORK/invalid-$label.out" 2>&1 || rc=$?
    if [ "$rc" = 1 ]; then
        pass "schema validation rejects an invalid document ($label)"
    else
        fail "schema validation did not reject an invalid document ($label) [exit $rc]"
    fi

    recipe_checks "$FUNC_ROOT" "$label"
}

# Drive real recipes through the CLI and use their results. Hermetic: only
# sandbox-local steps (mkdir/run/download over file:///clone of a local repo),
# plus the shipped `git` recipe, so no package manager or network is involved.
recipe_checks() {
    root=$1
    label=$2

    if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo "[smoke] note: git/curl unavailable; skipping recipe checks ($label)"
        return 0
    fi

    rhome="$WORK/recipe-home-$label"
    rcfg="$rhome/.config/tin"
    fx="$WORK/recipe-fixtures-$label"
    mkdir -p "$rcfg/recipes" "$fx"

    printf 'payload\n' > "$fx/asset.txt"
    git init -q "$fx/gitsrc"
    printf 'x\n' > "$fx/gitsrc/file"
    git -C "$fx/gitsrc" add file
    git -C "$fx/gitsrc" -c user.name=t -c user.email=t@t commit -qm init

    {
        printf '%s\n' 'name: setup' 'description: smoke recipe' 'steps:' \
            '  - name: make dir' '    mkdir: ~/from-recipe/dir' \
            '  - name: fetch asset' "    download: file://$fx/asset.txt" \
            '    to: ~/from-recipe/asset.txt' \
            '  - name: clone repo' "    clone: $fx/gitsrc" \
            '    to: ~/from-recipe/repo' \
            '  - name: guarded' '    run: touch ~/from-recipe/conditional' \
            "    if: commandExists('git')"
    } > "$rcfg/recipes/setup.yml"

    {
        printf '%s\n' 'identity:' '  name: Smoke User' '  email: smoke@example.com' \
            'recipes:' '  dev: [setup, git]' \
            'install:' '  - recipes: dev'
    } > "$rcfg/tinrc.yml"

    rc=0
    run_bounded 90 env HOME="$rhome" TIN_DIR="$root" PATH="$SAFE_PATH" \
        "$root/bin/tin" install > "$WORK/recipe-$label.out" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -q "recipe complete: setup" "$WORK/recipe-$label.out" \
        && grep -q "recipe complete: git" "$WORK/recipe-$label.out"; then
        pass "tin install ran config recipes ($label)"
    else
        fail "tin install did not run config recipes ($label) [exit $rc]"
        return 0
    fi

    if [ -d "$rhome/from-recipe/dir" ]; then
        pass "recipe mkdir created its directory ($label)"
    else
        fail "recipe mkdir ($label)"
    fi

    if [ -f "$rhome/from-recipe/asset.txt" ] && grep -q payload "$rhome/from-recipe/asset.txt"; then
        pass "recipe download fetched the asset ($label)"
    else
        fail "recipe download ($label)"
    fi

    if [ -f "$rhome/from-recipe/repo/file" ]; then
        pass "recipe clone created the repo ($label)"
    else
        fail "recipe clone ($label)"
    fi

    if [ -f "$rhome/from-recipe/conditional" ]; then
        pass "guarded recipe step ran ($label)"
    else
        fail "guarded recipe step ($label)"
    fi

    guname=$(env HOME="$rhome" git config --global user.name 2>/dev/null || true)
    if [ "$guname" = "Smoke User" ]; then
        pass "shipped git recipe applied the identity ($label)"
    else
        fail "shipped git recipe identity ($label) [got '$guname']"
    fi

    rc=0
    run_bounded 90 env HOME="$rhome" TIN_DIR="$root" PATH="$SAFE_PATH" \
        "$root/bin/tin" install > "$WORK/recipe-$label.2.out" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -q "skip clone (already exists)" "$WORK/recipe-$label.2.out"; then
        pass "recipe install is idempotent ($label)"
    else
        fail "recipe install idempotency ($label) [exit $rc]"
    fi
}

installer_checks() {
    installer=$TIN_PACKAGE_SMOKE_INSTALLER
    [ -f "$installer" ] || die "installer not found: $installer"
    printf '%s' "$REVISION" | grep -Eq '^[0-9a-f]{40}$' ||
        die "cannot exercise the installer without a resolved revision"
    base="$WORK/relbase"
    stage="$base/$REVISION"
    mkdir -p "$stage"
    cp "$ARCHIVE" "$stage/$ARCHIVE_BASE"
    cp "$CHECKSUM" "$stage/$ARCHIVE_BASE.sha256"
    inst_home="$WORK/installer-home"
    inst_tin="$inst_home/.tin"
    mkdir -p "$inst_home"
    rc=0
    run_bounded 120 env HOME="$inst_home" TIN_DIR="$inst_tin" \
        TIN_RELEASE_BASE_URL="file://$base" TIN_VERSION="$REVISION" \
        sh "$installer" --from-binary > "$WORK/installer.out" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
        pass "install.sh --from-binary consumed the candidate package"
        functional_checks "$inst_tin" installer
    else
        fail "install.sh --from-binary failed [exit $rc]"
    fi
}

SAFE_PATH=$(sanitize_path)
if ( PATH="$SAFE_PATH"; command -v zig >/dev/null 2>&1 ); then
    fail "zig is still resolvable under the sanitized PATH"
else
    pass "zig is not on PATH"
fi

EXECUTE=1
case "${TIN_SMOKE_EXECUTE:-1}" in
    0|false|no|False|No|FALSE|NO) EXECUTE=0 ;;
esac

check_neutral_defaults

if [ "$EXECUTE" = 1 ] && [ "$CHECKSUM_OK" = 1 ]; then
    functional_checks "$TIN_ROOT" unpacked
    if [ -n "${TIN_PACKAGE_SMOKE_INSTALLER:-}" ]; then
        installer_checks
    fi
else
    echo "[smoke] skipped binary execution (execute=$EXECUTE checksum_ok=$CHECKSUM_OK)"
fi

echo "[smoke] Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
