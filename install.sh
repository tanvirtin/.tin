#!/bin/sh
set -eu

REPO="tanvirtin/.tin"
TIN_DIR="${TIN_DIR:-$HOME/.tin}"
BIN_DIR="$TIN_DIR/bin"
ARTIFACTS_DIR="${TIN_ARTIFACTS:-$HOME/.config/tin/artifacts}"

MODE="${TIN_INSTALL_MODE:-auto}"
VERSION="${TIN_VERSION:-}"

info()    { echo "[tin] $*"; }
success() { echo "[tin] $*"; }
err()     { echo "[tin] ERROR: $*" >&2; }

usage() {
    echo "Install tin."
    echo ""
    echo "Usage: install.sh [options]"
    echo ""
    echo "Options:"
    echo "  --from-source      Build tin from source (requires zig)"
    echo "  --from-binary      Install a prebuilt release binary (no zig needed)"
    echo "  --version <tag>    Install a specific release tag (default: latest)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Environment:"
    echo "  TIN_INSTALL_MODE   auto | source | binary   (default: auto)"
    echo "  TIN_VERSION        release tag to install"
    echo "  TIN_FROM_SOURCE    set to force source mode"
    echo "  TIN_FROM_BINARY    set to force binary mode"
    echo "  TIN_DIR            install directory (default: ~/.tin)"
    echo "  TIN_ARTIFACTS      artifacts directory (default: ~/.config/tin/artifacts)"
    echo ""
    echo "Modes:"
    echo "  auto     use the latest release binary, fall back to source"
    echo "  binary   require a release binary (fail if unavailable)"
    echo "  source   always build from source"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --from-source) MODE="source" ;;
        --from-binary) MODE="binary" ;;
        --version)
            shift
            [ $# -gt 0 ] || { err "--version needs a tag"; exit 1; }
            VERSION="$1"
            ;;
        --version=*) VERSION="${1#--version=}" ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
    shift
done

if [ -n "${TIN_FROM_SOURCE:-}" ]; then MODE="source"; fi
if [ -n "${TIN_FROM_BINARY:-}" ]; then MODE="binary"; fi

case "$MODE" in
    auto|source|binary) ;;
    *) err "invalid mode: $MODE (expected auto, source, or binary)"; exit 1 ;;
esac

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) PLATFORM="darwin" ;;
    Linux)  PLATFORM="linux" ;;
    *)      err "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    arm64)   ARCH="aarch64" ;;
    *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

ARTIFACT="tin-${PLATFORM}-${ARCH}"

if [ ! -d "$TIN_DIR" ]; then
    info "Cloning .tin..."
    git clone "https://github.com/$REPO.git" "$TIN_DIR"
else
    info "Updating .tin..."
    (cd "$TIN_DIR" && git pull --ff-only 2>/dev/null) || info "Could not update (offline or uncommitted changes)"
fi

git -C "$TIN_DIR" config core.hooksPath .githooks

RELEASE_TAG=""
if [ "$MODE" != "source" ]; then
    if [ -n "$VERSION" ]; then
        RELEASE_TAG="$VERSION"
        info "Pinned to release $RELEASE_TAG"
    else
        info "Fetching latest release..."
        RELEASE_TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//' || true)
    fi
fi

DOWNLOADED=false
if [ "$MODE" != "source" ] && [ -n "$RELEASE_TAG" ]; then
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/${ARTIFACT}.tar.gz"
    info "Downloading $ARTIFACT ($RELEASE_TAG)..."
    mkdir -p "$BIN_DIR"
    if curl -fsSL "$DOWNLOAD_URL" | tar xz -C "$BIN_DIR" 2>/dev/null; then
        mv "$BIN_DIR/$ARTIFACT" "$BIN_DIR/tin" 2>/dev/null || true
        chmod +x "$BIN_DIR/tin"
        success "Installed tin $RELEASE_TAG (prebuilt)"
        DOWNLOADED=true
    else
        info "No prebuilt binary for $ARTIFACT at $RELEASE_TAG"
    fi
fi

if [ "$DOWNLOADED" = false ]; then
    if [ "$MODE" = "binary" ]; then
        err "No prebuilt binary available for $ARTIFACT (mode=binary)."
        err "Publish a release, or run with --from-source."
        exit 1
    fi
    info "Building from source..."
    if ! command -v zig >/dev/null 2>&1; then
        err "Zig not found. Install Zig to build from source."
        exit 1
    fi
    (cd "$TIN_DIR/engine" && zig build -Doptimize=ReleaseSafe)
    mkdir -p "$BIN_DIR"
    cp "$TIN_DIR/engine/zig-out/bin/tin" "$BIN_DIR/tin"
    success "Built from source"
fi

if ! "$BIN_DIR/tin" help >/dev/null 2>&1; then
    err "tin binary failed to run"
    exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ]; then
    info "No artifacts at $ARTIFACTS_DIR"
    info "Artifacts (skills, rules, dialects) live outside this repo."
    info "Clone or create yours there; tin reads it via TIN_ARTIFACTS."
else
    info "Using artifacts at $ARTIFACTS_DIR"
fi

if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    info ""
    info "Add tin to your PATH (add to ~/.zshrc or ~/.bashrc):"
    info "  export PATH=\"$BIN_DIR:\$PATH\""
    info ""
fi

info "Running tin install..."
"$BIN_DIR/tin" install

success "Done"
