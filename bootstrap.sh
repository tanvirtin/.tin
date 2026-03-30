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

# Clone repo if not present, otherwise pull latest
if [ ! -d "$TIN_DIR" ]; then
    info "Cloning .tin..."
    git clone "https://github.com/$REPO.git" "$TIN_DIR"
else
    info "Updating .tin..."
    cd "$TIN_DIR" && git pull --ff-only 2>/dev/null || info "Could not update (offline or uncommitted changes)"
fi

# Try to download pre-built binary
info "Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//' || true)

DOWNLOADED=false
if [ -n "$LATEST" ]; then
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST/${ARTIFACT}.tar.gz"
    info "Downloading $ARTIFACT ($LATEST)..."
    mkdir -p "$BIN_DIR"
    if curl -fsSL "$DOWNLOAD_URL" | tar xz -C "$BIN_DIR" 2>/dev/null; then
        mv "$BIN_DIR/$ARTIFACT" "$BIN_DIR/tin" 2>/dev/null || true
        chmod +x "$BIN_DIR/tin"
        success "Downloaded tin $LATEST"
        DOWNLOADED=true
    fi
fi

# Fallback: build from source
if [ "$DOWNLOADED" = false ]; then
    info "No release found. Building from source..."
    if ! command -v zig &>/dev/null; then
        err "Zig not found. Install Zig to build from source."
        exit 1
    fi
    cd "$TIN_DIR" && zig build -Doptimize=ReleaseSafe
    mkdir -p "$BIN_DIR"
    cp zig-out/bin/tin "$BIN_DIR/tin"
    success "Built from source"
fi

# Verify
if ! "$BIN_DIR/tin" help >/dev/null 2>&1; then
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

# Run tin install
info "Running tin install..."
"$BIN_DIR/tin" install

# Export Sn skills
info "Exporting Sn skills..."
"$BIN_DIR/tin" sn export claude 2>/dev/null || info "No Sn skills to export"

success "Done"
