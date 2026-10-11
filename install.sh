#!/bin/sh
set -eu

TIN_REPO_URL="${TIN_REPO_URL:-https://github.com/tanvirtin/.tin.git}"
TIN_RELEASE_BASE_URL="${TIN_RELEASE_BASE_URL:-https://github.com/tanvirtin/.tin/releases/download}"
TIN_DIR="${TIN_DIR:-$HOME/.tin}"

MODE="${TIN_INSTALL_MODE:-auto}"
VERSION="${TIN_VERSION:-}"

CLI_MODE=""
PIN_COMMIT=""
STAGE_ROOT=""
STAGE=""
WORK=""

info()    { echo "[tin] $*"; }
err()     { echo "[tin] ERROR: $*" >&2; }
die()     { err "$*"; exit 1; }
success() { echo "[tin] $*"; }

usage() {
    cat <<'EOF'
Install tin: the CLI and its matching runtime files.

This installs the tool only. It never applies your workstation settings.
Run `tin install` afterward to apply your environment.

Usage: install.sh [options]

Options:
  --from-source        Build from source (requires zig)
  --from-binary        Install a verified prebuilt release (no zig needed)
  --version <tag>      Install a specific release tag (default: latest)
  -h, --help           Show this help

Environment:
  TIN_INSTALL_MODE     auto | source | binary   (default: auto)
  TIN_VERSION          release tag to install
  TIN_FROM_SOURCE      non-empty value forces source mode
  TIN_FROM_BINARY      non-empty value forces binary mode
  TIN_DIR              install directory (default: ~/.tin)
  TIN_REPO_URL         git URL or path used for source builds
  TIN_RELEASE_BASE_URL base URL for release downloads

Modes:
  auto     use a verified release, fall back to source
  binary   require a verified release (fail if unavailable)
  source   always build from source
EOF
}

if [ -n "${TIN_FROM_SOURCE:-}" ] && [ -n "${TIN_FROM_BINARY:-}" ]; then
    die "conflicting environment: TIN_FROM_SOURCE and TIN_FROM_BINARY are both set"
fi
if [ -n "${TIN_FROM_SOURCE:-}" ]; then MODE="source"; fi
if [ -n "${TIN_FROM_BINARY:-}" ]; then MODE="binary"; fi

while [ $# -gt 0 ]; do
    case "$1" in
        --from-source)
            if [ -n "$CLI_MODE" ] && [ "$CLI_MODE" != "source" ]; then
                die "conflicting flags: --from-source and --from-binary"
            fi
            CLI_MODE="source" ;;
        --from-binary)
            if [ -n "$CLI_MODE" ] && [ "$CLI_MODE" != "binary" ]; then
                die "conflicting flags: --from-source and --from-binary"
            fi
            CLI_MODE="binary" ;;
        --version)
            shift
            [ $# -gt 0 ] || die "--version requires a tag"
            VERSION="$1" ;;
        --version=*)
            VERSION="${1#--version=}"
            [ -n "$VERSION" ] || die "--version requires a tag" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
if [ -n "$CLI_MODE" ]; then MODE="$CLI_MODE"; fi

case "$MODE" in
    auto|source|binary) ;;
    *) die "invalid mode: $MODE (expected auto, source, or binary)" ;;
esac

if [ -n "$VERSION" ]; then
    case "$VERSION" in
        -*|*..*) die "invalid version: $VERSION" ;;
    esac
    case "$VERSION" in
        *[!A-Za-z0-9._/-]*) die "invalid version: $VERSION" ;;
    esac
fi

case "$(uname -s)" in
    Darwin) PLATFORM="darwin" ;;
    Linux)  PLATFORM="linux" ;;
    *)      die "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)   HOST_ARCH="x86_64" ;;
    aarch64|arm64)  HOST_ARCH="aarch64" ;;
    *)              die "unsupported architecture: $(uname -m)" ;;
esac
ARTIFACT="tin-${PLATFORM}-${HOST_ARCH}"

cleanup() {
    if [ -n "$STAGE_ROOT" ] && [ -d "$STAGE_ROOT" ]; then rm -rf "$STAGE_ROOT"; fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
    :
}
trap cleanup EXIT HUP INT TERM

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tin-install.XXXXXX")"

is_git_worktree() {
    git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

check_clean_checkout() {
    dir="$1"
    if [ -d "$dir" ] && is_git_worktree "$dir"; then
        dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            die "refusing to modify a dirty checkout at $dir; commit or move your changes first"
        fi
    fi
}

resolve_repo_slug() {
    url="$TIN_REPO_URL"
    case "$url" in
        *github.com[:/]*)
            rest="${url#*github.com}"
            rest="${rest#:}"
            rest="${rest#/}"
            printf '%s' "${rest%.git}" ;;
        *) printf '%s' "tanvirtin/.tin" ;;
    esac
}

fetch_latest_tag() {
    slug="$(resolve_repo_slug)"
    body="$(curl -fsSL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null || true)"
    printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

resolve_pin_commit() {
    tag="$1"
    [ -n "$tag" ] || return 0
    if [ -d "$TIN_DIR" ] && is_git_worktree "$TIN_DIR"; then
        git -C "$TIN_DIR" rev-parse --verify --quiet "$tag^{commit}" 2>/dev/null || true
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        die "no sha256 tool available (need sha256sum, shasum, or openssl)"
    fi
}

validate_revision() {
    rev="$1"
    if [ -z "$rev" ]; then
        die "package .tin-revision is empty"
    fi
    case "$rev" in
        *[!0-9a-f]*) die "package .tin-revision is not a lowercase commit hash" ;;
    esac
    if [ "${#rev}" -ne 40 ]; then
        die "package .tin-revision is not a full commit hash"
    fi
}

stage_package() {
    archive="$1"
    list="$WORK/members.txt"
    if ! tar -tzf "$archive" > "$list" 2>/dev/null; then
        die "package is not a readable tar.gz: $(basename "$archive")"
    fi
    if [ ! -s "$list" ]; then
        die "package archive is empty: $(basename "$archive")"
    fi
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        m="${member#./}"
        case "$m" in
            /*) die "unsafe package path (absolute): $member" ;;
        esac
        case "/$m" in
            */../*|*/..) die "unsafe package path (parent): $member" ;;
        esac
        case "$m" in
            "$ARTIFACT"|"$ARTIFACT"/*) ;;
            *) die "unsafe package path (outside $ARTIFACT/): $member" ;;
        esac
    done < "$list"

    ext="$STAGE_ROOT/extract"
    mkdir -p "$ext"
    if ! tar -xzf "$archive" -C "$ext" 2>/dev/null; then
        die "package failed to extract: $(basename "$archive")"
    fi
    root="$ext/$ARTIFACT"
    if [ ! -d "$root" ]; then
        if [ -e "$root" ]; then
            die "unsupported package layout: '$ARTIFACT' is a file, not the root directory; this is an older release format"
        fi
        die "unsupported package layout: missing root directory '$ARTIFACT/'"
    fi

    [ -f "$root/bin/tin" ] || die "package missing bin/tin"
    [ -f "$root/.tin-revision" ] || die "package missing .tin-revision"
    [ -d "$root/engine/src/schemas" ] || die "package missing engine/src/schemas/"
    [ -d "$root/environment" ] || die "package missing environment/"
    [ -f "$root/tinrc.yml" ] || die "package missing tinrc.yml"

    rev="$(cat "$root/.tin-revision")"
    validate_revision "$rev"
    if [ -n "$PIN_COMMIT" ] && [ "$PIN_COMMIT" != "$rev" ]; then
        die "package revision $rev does not match $VERSION ($PIN_COMMIT)"
    fi

    find "$root" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print > "$WORK/special.txt" 2>/dev/null || true
    while IFS= read -r special; do
        [ -n "$special" ] || continue
        if [ -L "$special" ]; then
            tgt="$(readlink "$special")"
            case "$tgt" in
                /*) die "package contains a symlink with an absolute target: $(basename "$special") -> $tgt" ;;
            esac
            case "/$tgt/" in
                */../*) die "package contains a symlink escaping its root: $(basename "$special") -> $tgt" ;;
            esac
        else
            die "package contains an unsupported special file: $(basename "$special")"
        fi
    done < "$WORK/special.txt"

    mv "$root" "$STAGE"
    chmod +x "$STAGE/bin/tin"
}

acquire_binary() {
    tag="$1"
    base="$TIN_RELEASE_BASE_URL/$tag"
    archive_name="$ARTIFACT.tar.gz"
    archive="$WORK/$archive_name"
    sidecar="$WORK/$archive_name.sha256"

    info "Downloading $ARTIFACT ($tag)..."
    if ! curl -fsSL -o "$archive" "$base/$archive_name" 2>/dev/null; then
        return 1
    fi
    if ! curl -fsSL -o "$sidecar" "$base/$archive_name.sha256" 2>/dev/null; then
        err "no checksum sidecar at $base/$archive_name.sha256"
        die "refusing to install an unverified package; older release artifacts are not supported"
    fi
    expected="$(awk 'NR==1 {print $1}' "$sidecar")"
    actual="$(sha256_of "$archive")"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        die "checksum mismatch for $archive_name (expected ${expected:-none}, got ${actual:-none})"
    fi
    sidecar_name="$(awk 'NR==1 {print $2}' "$sidecar")"
    if [ -n "$sidecar_name" ] && [ "$sidecar_name" != "$archive_name" ]; then
        die "checksum sidecar names '$sidecar_name', expected '$archive_name'"
    fi
    stage_package "$archive"
}

clone_repo() {
    dest="$1"
    info "Cloning $TIN_REPO_URL..."
    git clone --quiet "$TIN_REPO_URL" "$dest" || die "failed to clone $TIN_REPO_URL"
}

build_source() {
    src="$1"
    if ! command -v zig >/dev/null 2>&1; then
        die "zig not found; install Zig to build from source (or use --from-binary)"
    fi
    info "Building tin from source..."
    ( cd "$src/engine" && zig build install-tin -Doptimize=ReleaseSafe ) || die "source build failed"
}

stage_source() {
    src="$1"
    commit="$2"
    if [ ! -f "$src/engine/zig-out/bin/tin" ]; then
        die "source build did not produce engine/zig-out/bin/tin"
    fi
    [ -d "$src/engine/src/schemas" ] || die "source tree missing engine/src/schemas"
    [ -d "$src/environment" ] || die "source tree missing environment/"
    [ -f "$src/tinrc.yml" ] || die "source tree missing tinrc.yml"
    mkdir -p "$STAGE/bin" "$STAGE/engine/src"
    cp "$src/engine/zig-out/bin/tin" "$STAGE/bin/tin"
    chmod +x "$STAGE/bin/tin"
    cp -R "$src/engine/src/schemas" "$STAGE/engine/src/schemas"
    cp -R "$src/environment" "$STAGE/environment"
    cp "$src/tinrc.yml" "$STAGE/tinrc.yml"
    printf '%s\n' "$commit" > "$STAGE/.tin-revision"
}

prepare_source() {
    if [ -n "$VERSION" ]; then
        src="$WORK/src"
        clone_repo "$src"
        git -C "$src" checkout --quiet "$VERSION" || die "could not check out version $VERSION"
        commit="$(git -C "$src" rev-parse HEAD)"
        if [ -n "$PIN_COMMIT" ] && [ "$PIN_COMMIT" != "$commit" ]; then
            die "resolved $VERSION to $commit but expected $PIN_COMMIT"
        fi
        build_source "$src"
        stage_source "$src" "$commit"
    else
        check_clean_checkout "$TIN_DIR"
        if [ -d "$TIN_DIR" ] && is_git_worktree "$TIN_DIR"; then
            src="$TIN_DIR"
        else
            src="$WORK/src"
            clone_repo "$src"
        fi
        commit="$(git -C "$src" rev-parse HEAD)"
        build_source "$src"
        stage_source "$src" "$commit"
    fi
}

MEMBER_LIST=".tin-revision tinrc.yml environment engine/src/schemas bin/tin"
PHASE="backup"

restore() {
    bk="$STAGE_ROOT/backup"
    for rel in $MEMBER_LIST; do
        if [ -e "$bk/$rel" ] || [ -L "$bk/$rel" ]; then
            rm -rf "$TIN_DIR/$rel"
            mkdir -p "$(dirname "$TIN_DIR/$rel")"
            mv "$bk/$rel" "$TIN_DIR/$rel"
        elif [ "$PHASE" = "place" ]; then
            rm -rf "$TIN_DIR/$rel"
        fi
    done
}

promote() {
    bk="$STAGE_ROOT/backup"
    PHASE="backup"
    for rel in $MEMBER_LIST; do
        if [ -e "$TIN_DIR/$rel" ] || [ -L "$TIN_DIR/$rel" ]; then
            mkdir -p "$bk/$(dirname "$rel")" || { restore; die "could not create backup for $rel"; }
            mv "$TIN_DIR/$rel" "$bk/$rel" || { restore; die "could not back up $rel"; }
        fi
    done
    PHASE="place"
    for rel in $MEMBER_LIST; do
        [ -e "$STAGE/$rel" ] || { restore; die "staged member missing: $rel"; }
        mkdir -p "$(dirname "$TIN_DIR/$rel")" || { restore; die "could not create directory for $rel"; }
        mv "$STAGE/$rel" "$TIN_DIR/$rel" || { restore; die "could not install $rel"; }
    done
    if ! "$TIN_DIR/bin/tin" help >/dev/null 2>&1; then
        restore
        die "installed tin failed to run: $TIN_DIR/bin/tin help"
    fi
    rm -rf "$bk"
}

check_clean_checkout "$TIN_DIR"
mkdir -p "$TIN_DIR"
STAGE_ROOT="$TIN_DIR/.tin-install-$$"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"
STAGE="$STAGE_ROOT/stage"

if [ -n "$VERSION" ]; then
    PIN_COMMIT="$(resolve_pin_commit "$VERSION")"
fi

case "$MODE" in
    source)
        prepare_source
        ;;
    binary)
        tag="$VERSION"
        if [ -z "$tag" ]; then
            info "Fetching latest release..."
            tag="$(fetch_latest_tag)"
            [ -n "$tag" ] || die "could not resolve the latest release"
        fi
        acquire_binary "$tag" || die "no prebuilt binary available for $ARTIFACT at $tag"
        ;;
    auto)
        tag="$VERSION"
        if [ -z "$tag" ]; then
            info "Fetching latest release..."
            tag="$(fetch_latest_tag)"
        fi
        if [ -n "$tag" ]; then
            if acquire_binary "$tag"; then
                :
            else
                info "No prebuilt binary for $ARTIFACT at $tag; building from source"
                VERSION="$tag"
                if [ -z "$PIN_COMMIT" ]; then
                    PIN_COMMIT="$(resolve_pin_commit "$tag")"
                fi
                prepare_source
            fi
        else
            info "No release found; building from source"
            prepare_source
        fi
        ;;
esac

promote

REV="$(cat "$TIN_DIR/.tin-revision" 2>/dev/null || printf 'unknown')"
success "Installed tin ($REV) to $TIN_DIR/bin/tin"
info "This installer did not apply your workstation settings."
info "Run 'tin install' to apply them when you are ready."

case ":$PATH:" in
    *":$TIN_DIR/bin:"*) ;;
    *) info "Add tin to PATH: export PATH=\"$TIN_DIR/bin:\$PATH\"" ;;
esac

exit 0
