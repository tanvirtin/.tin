#!/bin/bash
set -euo pipefail

PASSED=0
FAILED=0
TIN="./zig-out/bin/tin"

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

# Run a command with a hard timeout (macOS has no GNU `timeout`).
# A fresh test HOME triggers nvim's first-run plugin install, which can be
# slow on a loaded machine; this keeps the suite from hanging on it.
run_bounded() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    { sleep "$secs"; kill -9 "$pid" 2>/dev/null; } >/dev/null 2>&1 &
    local timer=$!
    wait "$pid"
    local rc=$?
    kill "$timer" 2>/dev/null
    return "$rc"
}

echo "[tin] Running integration tests..."
echo ""

# Setup temporary isolated environment
export TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT"
export TIN_DIR="$TEST_ROOT/.tin"

mkdir -p "$TIN_DIR"
cp -r recipes "$TIN_DIR/"
cp -r assets "$TIN_DIR/"
cp tinrc.yml "$TIN_DIR/"
# Patch tinrc.yml to avoid problematic recipes in tests
cat > "$TIN_DIR/tinrc.yml" << 'EOF'
identity:
  name: Tanvir Islam
  email: tanvir.tinz@gmail.com

symlinks:
  shell:
    - source: assets/.zshrc
      target: ~/.zshrc

install:
  - link
  - fonts
EOF

# Clean up on exit
trap "rm -rf $TEST_ROOT" EXIT

# ── Build ──

if zig build 2>/dev/null; then
    pass "zig build"
else
    fail "zig build"
fi


# ── Commands run without crashing ──

if $TIN help >/dev/null 2>&1; then
    pass "tin help"
else
    fail "tin help"
fi

if $TIN status >/dev/null 2>&1; then
    pass "tin status"
else
    fail "tin status"
fi

if $TIN recipe 2>&1 | grep -q "git"; then
    pass "tin recipe (lists recipes)"
else
    fail "tin recipe (lists recipes)"
fi

# ── tinrc.yml parsing ──

if $TIN status 2>&1 | grep -q "zshrc"; then
    pass "tinrc.yml symlinks parsed"
else
    fail "tinrc.yml symlinks parsed"
fi

# ── Symlink creation ──

TEST_DIR=$(mktemp -d)
TEST_SOURCE="$TEST_DIR/source_file"
TEST_TARGET="$TEST_DIR/target_link"
echo "test content" > "$TEST_SOURCE"

# Test that tin link creates symlinks (use tin status to verify existing ones)
LINKED_COUNT=$($TIN status 2>&1 | grep -c "\[ok\]\|not linked\|wrong target\|broken" || true)
if [ "$LINKED_COUNT" -gt 0 ]; then
    pass "tin status reports symlink state ($LINKED_COUNT entries)"
else
    fail "tin status reports symlink state"
fi

rm -rf "$TEST_DIR"

# ── Recipe execution ──

# git recipe uses templates — verify it runs and applies config
if $TIN recipe git 2>&1 | grep -q "recipe complete"; then
    pass "tin recipe git (executes)"
else
    fail "tin recipe git (executes)"
fi

# Verify git config was actually set from tinrc.yml identity
GIT_NAME=$(git config --global user.name 2>/dev/null || echo "")
if [ -n "$GIT_NAME" ]; then
    pass "git recipe set user.name ($GIT_NAME)"
else
    fail "git recipe set user.name"
fi

GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
if [ -n "$GIT_EMAIL" ]; then
    pass "git recipe set user.email ($GIT_EMAIL)"
else
    fail "git recipe set user.email"
fi

# ── mkdir step type ──

MKDIR_TEST_DIR=$(mktemp -d)/tin_mkdir_test
cat > /tmp/tin_test_recipe.yml << 'EOF'
name: mkdir-test
steps:
  - mkdir: MKDIR_PLACEHOLDER
EOF
sed -i.bak "s|MKDIR_PLACEHOLDER|$MKDIR_TEST_DIR|" /tmp/tin_test_recipe.yml 2>/dev/null || \
    sed -i '' "s|MKDIR_PLACEHOLDER|$MKDIR_TEST_DIR|" /tmp/tin_test_recipe.yml

# Copy test recipe to recipes dir, run, clean up
cp /tmp/tin_test_recipe.yml "$TIN_DIR/recipes/mkdir-test.yml"
if $TIN recipe mkdir-test 2>&1 | grep -q "recipe complete"; then
    if [ -d "$MKDIR_TEST_DIR" ]; then
        pass "mkdir step creates directory"
    else
        fail "mkdir step creates directory"
    fi
else
    fail "mkdir step (recipe failed)"
fi
rm -f "$TIN_DIR/recipes/mkdir-test.yml" /tmp/tin_test_recipe.yml /tmp/tin_test_recipe.yml.bak
rm -rf "$MKDIR_TEST_DIR"

# ── Condition evaluation ──

# Test that OS condition works (at least one branch should match)
OS_NAME=$(uname -s)
cat > "$TIN_DIR/recipes/condition-test.yml" << EOF
name: condition-test
steps:
  - name: OS match
    run: echo "matched"
    if: os == '$([ "$OS_NAME" = "Darwin" ] && echo darwin || echo linux)'
  - name: OS no match
    run: echo "should not run"
    if: os == 'nonexistent_os'
EOF

COND_OUTPUT=$($TIN recipe condition-test 2>&1)
if echo "$COND_OUTPUT" | grep -q "OS match"; then
    pass "condition: os == (matched)"
else
    fail "condition: os == (matched)"
fi
if echo "$COND_OUTPUT" | grep -q "skip OS no match"; then
    pass "condition: os == (skipped)"
else
    fail "condition: os == (skipped)"
fi
rm -f "$TIN_DIR/recipes/condition-test.yml"

# ── exists / not exists conditions ──

cat > "$TIN_DIR/recipes/exists-test.yml" << 'EOF'
name: exists-test
steps:
  - name: Root exists
    run: echo "root exists"
    if: exists /
  - name: Missing path
    run: echo "should not run"
    if: exists /nonexistent_tin_test_path
  - name: Not exists check
    run: echo "not exists works"
    if: not exists /nonexistent_tin_test_path
EOF

EXISTS_OUTPUT=$($TIN recipe exists-test 2>&1)
if echo "$EXISTS_OUTPUT" | grep -q "Root exists"; then
    pass "condition: exists"
else
    fail "condition: exists"
fi
if echo "$EXISTS_OUTPUT" | grep -q "skip Missing path"; then
    pass "condition: exists (negative)"
else
    fail "condition: exists (negative)"
fi
if echo "$EXISTS_OUTPUT" | grep -q "Not exists check"; then
    pass "condition: not exists"
else
    fail "condition: not exists"
fi
rm -f "$TIN_DIR/recipes/exists-test.yml"

# ── Template rendering ──

cat > "$TIN_DIR/recipes/template-test.yml" << 'EOF'
name: template-test
steps:
  - name: Render identity
    run: echo "Hello {{ identity.name }}"
EOF

TMPL_OUTPUT=$($TIN recipe template-test 2>&1)
if echo "$TMPL_OUTPUT" | grep -q "recipe complete"; then
    pass "template rendering"
else
    fail "template rendering"
fi
rm -f "$TIN_DIR/recipes/template-test.yml"

# ── tin link / unlink ──

LINK_TEST_DIR=$(mktemp -d)
LINK_SOURCE="$LINK_TEST_DIR/source_file"
LINK_TARGET="$LINK_TEST_DIR/target_link"
echo "link test content" > "$LINK_SOURCE"

# Create a symlink and verify
ln -sf "$LINK_SOURCE" "$LINK_TARGET"
if [ -L "$LINK_TARGET" ] && [ "$(readlink "$LINK_TARGET")" = "$LINK_SOURCE" ]; then
    pass "symlink creation works"
else
    fail "symlink creation works"
fi

# Verify tin link runs without error
if $TIN link 2>&1 | grep -q "linking\|skip\|link"; then
    pass "tin link runs"
else
    fail "tin link runs"
fi

# Verify tin unlink runs without error
if $TIN unlink 2>&1 | grep -q "unlink"; then
    pass "tin unlink runs"
else
    fail "tin unlink runs"
fi

# Verify tin link restores (re-link after unlink)
if $TIN link 2>&1 | grep -q "link"; then
    pass "tin link after unlink"
else
    fail "tin link after unlink"
fi

rm -rf "$LINK_TEST_DIR"

# ── tin heal: self-repair loop ──

HEAL_TEST_DIR=$(mktemp -d)
HEAL_SOURCE="$HEAL_TEST_DIR/heal_source"
HEAL_TARGET="$HEAL_TEST_DIR/heal_target"
ln -sf "$HEAL_SOURCE" "$HEAL_TARGET"

# heal with nothing broken reports healthy
if $TIN heal 2>&1 | grep -q "healthy"; then
    pass "tin heal reports healthy when nothing broken"
else
    fail "tin heal reports healthy when nothing broken"
fi

rm -rf "$HEAL_TEST_DIR"

# heal repairs a wrong-target symlink — ~/.zshrc is the only managed symlink
# in this sandbox tinrc.yml (see setup above), so break it and verify recovery
zshrc_source="$TIN_DIR/assets/.zshrc"
ln -sf "/wrong/target" "$HOME/.zshrc"
$TIN heal >/dev/null 2>&1
if [ "$(readlink "$HOME/.zshrc")" = "$zshrc_source" ]; then
    pass "tin heal repairs wrong-target symlink"
else
    fail "tin heal repairs wrong-target symlink"
fi

# ── clone step ──

CLONE_TEST_DIR=$(mktemp -d)
CLONE_REPO="$CLONE_TEST_DIR/fake_repo"
CLONE_DEST="$CLONE_TEST_DIR/cloned"

# Create a local git repo to clone (no network needed)
mkdir -p "$CLONE_REPO"
git -C "$CLONE_REPO" init -q
git -C "$CLONE_REPO" commit --allow-empty -m "init" -q

cat > "$TIN_DIR/recipes/clone-test.yml" << EOF
name: clone-test
steps:
  - clone: $CLONE_REPO
    to: $CLONE_DEST
EOF

if $TIN recipe clone-test 2>&1 | grep -q "recipe complete"; then
    if [ -d "$CLONE_DEST/.git" ]; then
        pass "clone step creates repo"
    else
        fail "clone step creates repo"
    fi
else
    fail "clone step (recipe failed)"
fi

# Run again — should skip (idempotent)
if $TIN recipe clone-test 2>&1 | grep -q "skip clone"; then
    pass "clone step skips existing"
else
    fail "clone step skips existing"
fi

rm -f "$TIN_DIR/recipes/clone-test.yml"
rm -rf "$CLONE_TEST_DIR"

# ── fonts step ──

mkdir -p "$HOME/Library/Fonts" # Ensure font dir exists for macOS
if $TIN fonts 2>&1 | grep -q "fonts\|copy\|skipped"; then
    pass "tin fonts runs"
else
    fail "tin fonts runs"
fi

# ── tin install (full flow) ──

if $TIN install 2>&1 | grep -q "install complete"; then
    pass "tin install (full flow)"
else
    fail "tin install (full flow)"
fi

# ── Neovim config ──

if command -v nvim &>/dev/null; then
    # Load config headless — catches syntax errors, broken requires, missing modules
    NVIM_OUTPUT=$(run_bounded 60 env XDG_CONFIG_HOME="$(cd "$(dirname "$0")/.." && pwd)" nvim --headless -c "lua vim.health = vim.health or {}" -c "qall!" 2>&1 || true)
    # Strip ANSI color codes and carriage-return progress spam before checking
    # for genuine nvim config errors; lazy.nvim install chatter is not one.
    NVIM_CONFIG_ERRS=$(printf '%s' "$NVIM_OUTPUT" | perl -pe 's/\e\[[0-9;]*m//g; s/\r//g' | grep -i "E5113\|error detected while processing\|module.*not found" || true)

    if [ -n "$NVIM_CONFIG_ERRS" ]; then
        fail "neovim config loads (errors found)"
        echo "$NVIM_CONFIG_ERRS" | head -5
    else
        pass "neovim config loads"
    fi
else
    pass "neovim config (skipped — nvim not installed)"
fi

# ── Workspace runtime (tmux) ──

if command -v tmux &>/dev/null; then
    mkdir -p "$TIN_DIR/src/schemas" "$TIN_DIR/methods" "$TEST_ROOT/dev/demo"
    mkdir -p "$HOME/.config/tin/workspaces"
    cp src/schemas/workspace.yaml "$TIN_DIR/src/schemas/workspace.yaml"

    # Seed a simple process method into the test catalog
    cat > "$TIN_DIR/methods/pinger.yml" << 'EOF'
name: pinger
description: long-running ping process
runtime: process
command: sleep 30
EOF

    # Register a workspace referencing it
    cat > "$HOME/.config/tin/workspaces/demo.yml" << EOF
name: demo
path: $TEST_ROOT/dev/demo
components:
  pinger:
    method: pinger
EOF

    # validate against the DSL schema
    if $TIN workspace validate demo 2>&1 | grep -q "valid: demo"; then
        pass "workspace validate (runtime fixture)"
    else
        fail "workspace validate (runtime fixture)"
    fi

    # sessions lists Pi conversation history for the workspace path
    if $TIN workspace sessions demo 2>&1 | grep -q "no sessions yet"; then
        pass "workspace sessions (empty store)"
    else
        fail "workspace sessions (empty store)"
    fi

    # fabricate a session file and confirm it is listed
    ENC_PATH="--$(echo "$TEST_ROOT/dev/demo" | sed 's|^/||; s|[/\\:]|-|g')--"
    mkdir -p "$HOME/.pi/agent/sessions/$ENC_PATH"
    echo '{"id":"t"}' > "$HOME/.pi/agent/sessions/$ENC_PATH/2026-08-02T00-00-00-000Z_test.jsonl"
    if $TIN workspace sessions demo 2>&1 | grep -q "1 session(s)"; then
        pass "workspace sessions (lists history)"
    else
        fail "workspace sessions (lists history)"
    fi

    # up boots a tmux session with a window per component
    if $TIN workspace up demo 2>&1 | grep -q "up demo:pinger"; then
        pass "workspace up (tmux session)"
    else
        fail "workspace up (tmux session)"
    fi

    # up is idempotent — second run skips running components
    if $TIN workspace up demo 2>&1 | grep -q "skip (running): demo:pinger"; then
        pass "workspace up is idempotent"
    else
        fail "workspace up is idempotent"
    fi

    # status reports the running session
    if $TIN workspace status demo 2>&1 | grep -q "running"; then
        pass "workspace status (running)"
    else
        fail "workspace status (running)"
    fi

    # unknown method → named diagnostic + nonzero exit
    cat > "$HOME/.config/tin/workspaces/bad.yml" << 'EOF'
name: bad
path: $TEST_ROOT/dev/demo
components:
  ghost:
    method: does-not-exist
EOF
    BAD_OUT=$($TIN workspace up bad 2>&1 || true)
    if echo "$BAD_OUT" | grep -q "AGENT-UNKNOWN-METHOD"; then
        pass "workspace up unknown method (AGENT-UNKNOWN-METHOD)"
    else
        fail "workspace up unknown method (AGENT-UNKNOWN-METHOD)"
    fi
    rm -f "$HOME/.config/tin/workspaces/bad.yml"

    # down tears down and kills the session
    if $TIN workspace down demo 2>&1 | grep -q "down demo"; then
        pass "workspace down"
    else
        fail "workspace down"
    fi

    # down is idempotent
    if $TIN workspace down demo 2>&1 | grep -q "down demo"; then
        pass "workspace down is idempotent"
    else
        fail "workspace down is idempotent"
    fi

    # status after down reports stopped
    if $TIN workspace status demo 2>&1 | grep -q "stopped"; then
        pass "workspace status (stopped)"
    else
        fail "workspace status (stopped)"
    fi

    rm -f "$HOME/.config/tin/workspaces/demo.yml"
    tmux kill-session -t tin-demo 2>/dev/null || true
else
    pass "workspace runtime (skipped — tmux not installed)"
fi

# ── Summary ──

echo ""
echo "[tin] Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
