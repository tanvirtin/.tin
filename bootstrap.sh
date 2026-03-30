#!/bin/bash
set -euo pipefail

REPO="tanvirtin/.tin"
TIN_DIR="${TIN_DIR:-$HOME/.tin}"
BIN_DIR="$TIN_DIR/bin"

info()    { echo "[tin] $*"; }
success() { echo "[tin] $*"; }
err()     { echo "[tin] ERROR: $*" >&2; }

# Detect platform
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

# Clone repo if not present
if [ ! -d "$TIN_DIR" ]; then
    info "Cloning .tin..."
    git clone "https://github.com/$REPO.git" "$TIN_DIR"
else
    info "Found existing .tin at $TIN_DIR"
fi

# Get latest release tag
info "Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//')

if [ -z "$LATEST" ]; then
    err "Could not determine latest release. Building from source..."
    if ! command -v zig &>/dev/null; then
        err "Zig not found. Install Zig 0.15.2 or create a release at github.com/$REPO"
        exit 1
    fi
    cd "$TIN_DIR" && zig build -Doptimize=ReleaseSafe
    mkdir -p "$BIN_DIR"
    cp zig-out/bin/tin "$BIN_DIR/tin"
    success "Built from source"
else
    # Download pre-built binary
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST/${ARTIFACT}.tar.gz"
    info "Downloading $ARTIFACT ($LATEST)..."

    mkdir -p "$BIN_DIR"
    curl -fsSL "$DOWNLOAD_URL" | tar xz -C "$BIN_DIR"
    mv "$BIN_DIR/$ARTIFACT" "$BIN_DIR/tin" 2>/dev/null || true
    chmod +x "$BIN_DIR/tin"
    success "Downloaded tin $LATEST"
fi

# Verify
if "$BIN_DIR/tin" help >/dev/null 2>&1; then
    success "tin is ready at $BIN_DIR/tin"
else
    err "tin binary failed to run"
    exit 1
fi

# PATH hint
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    info ""
    info "Add tin to your PATH (add to ~/.zshrc or ~/.bashrc):"
    info "  export PATH=\"$BIN_DIR:\$PATH\""
    info ""
fi

info "Run 'tin install' to set up your environment"
