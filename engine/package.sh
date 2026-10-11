#!/bin/sh
set -eu

die() {
    echo "[package] ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: package.sh <binary> <artifact-name> <output-dir> <revision>"
    echo ""
    echo "  <binary>         built tin executable to package"
    echo "  <artifact-name>  one of tin-{darwin|linux}-{aarch64|x86_64}"
    echo "  <output-dir>     directory for <artifact>.tar.gz and <artifact>.tar.gz.sha256"
    echo "  <revision>       full 40-character lowercase git commit"
    echo ""
    echo "Runtime files come from TIN_PACKAGE_SOURCE_ROOT, or the repository"
    echo "root containing this script. Only git-tracked files are packaged."
}

if [ "$#" -ne 4 ]; then
    usage >&2
    exit 2
fi

BINARY=$1
ARTIFACT=$2
OUTPUT_DIR=$3
REVISION=$4

case "$ARTIFACT" in
    tin-darwin-aarch64|tin-darwin-x86_64|tin-linux-aarch64|tin-linux-x86_64) ;;
    *) die "artifact name must be tin-{darwin|linux}-{aarch64|x86_64}: $ARTIFACT" ;;
esac

printf '%s' "$REVISION" | grep -Eq '^[0-9a-f]{40}$' ||
    die "revision must be a full 40-character lowercase git commit: $REVISION"

[ -f "$BINARY" ] || die "binary not found: $BINARY"
[ -x "$BINARY" ] || die "binary is not executable: $BINARY"

for tool in git tar mktemp cp grep awk; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

SHA_CMD=
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
else
    die "no sha256 tool found (need sha256sum or shasum)"
fi

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
DEFAULT_SOURCE=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${TIN_PACKAGE_SOURCE_ROOT:-$DEFAULT_SOURCE}
SOURCE_ROOT=$(CDPATH= cd "$SOURCE_ROOT" && pwd)

[ -d "$SOURCE_ROOT/.git" ] || die "source checkout is not a git work tree: $SOURCE_ROOT"

HEAD_REV=$(git -C "$SOURCE_ROOT" rev-parse --verify HEAD 2>/dev/null || true)
if [ -n "$HEAD_REV" ]; then
    [ "$HEAD_REV" = "$REVISION" ] ||
        die "revision mismatch: source checkout is at $HEAD_REV, requested $REVISION"
else
    echo "[package] notice: source checkout has no HEAD commit; revision provenance not verified" >&2
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd "$OUTPUT_DIR" && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tin-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

FILES="$WORK/tracked-files"
git -C "$SOURCE_ROOT" -c core.quotePath=false ls-files -- \
    engine/src/schemas environment tinrc.yml > "$FILES"
[ -s "$FILES" ] || die "no git-tracked runtime files under engine/src/schemas, environment, tinrc.yml"

if git -C "$SOURCE_ROOT" ls-files -s -- engine/src/schemas environment tinrc.yml | grep -q '^120000 '; then
    die "refusing to package tracked symlinks in the runtime tree"
fi

if grep -Eq '(^|/)(\.env[^/]*|[^/]*\.secret|[^/]*\.token|auth\.json)$' "$FILES"; then
    die "refusing to package secret-looking tracked files"
fi

ROOT="$WORK/$ARTIFACT"
mkdir -p "$ROOT/bin"
cp "$BINARY" "$ROOT/bin/tin"
chmod 755 "$ROOT/bin/tin"
printf '%s\n' "$REVISION" > "$ROOT/.tin-revision"

if [ -n "$HEAD_REV" ]; then
    git -C "$SOURCE_ROOT" archive --format=tar "$REVISION" -- \
        engine/src/schemas environment tinrc.yml > "$WORK/runtime.tar"
    tar -xf "$WORK/runtime.tar" -C "$ROOT"
else
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dest="$ROOT/$rel"
        mkdir -p "${dest%/*}"
        cp -p "$SOURCE_ROOT/$rel" "$dest"
    done < "$FILES"
fi

[ -f "$ROOT/tinrc.yml" ] || die "tracked tinrc.yml is missing from the source checkout"
[ -f "$ROOT/engine/src/schemas/skill.yaml" ] || die "tracked engine/src/schemas/skill.yaml is missing"

ARCHIVE="$OUTPUT_DIR/$ARTIFACT.tar.gz"
SIDECAR="$OUTPUT_DIR/$ARTIFACT.tar.gz.sha256"

( cd "$WORK" && COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" "$ARTIFACT" )

DIGEST=$($SHA_CMD "$ARCHIVE" | awk '{print $1}')
printf '%s  %s\n' "$DIGEST" "$ARTIFACT.tar.gz" > "$SIDECAR"

echo "[package] revision $REVISION"
echo "[package] wrote $ARCHIVE"
echo "[package] wrote $SIDECAR"
