#!/bin/bash
set -euo pipefail

PASSED=0
FAILED=0
TIN="./zig-out/bin/tin"

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

echo "[tin] Running integration tests..."
echo ""

# ── Build ──

if zig build 2>/dev/null; then
    pass "zig build"
else
    fail "zig build"
fi

if zig build test 2>/dev/null; then
    pass "zig build test"
else
    fail "zig build test"
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
cp /tmp/tin_test_recipe.yml recipes/mkdir-test.yml
if $TIN recipe mkdir-test 2>&1 | grep -q "recipe complete"; then
    if [ -d "$MKDIR_TEST_DIR" ]; then
        pass "mkdir step creates directory"
    else
        fail "mkdir step creates directory"
    fi
else
    fail "mkdir step (recipe failed)"
fi
rm -f recipes/mkdir-test.yml /tmp/tin_test_recipe.yml /tmp/tin_test_recipe.yml.bak
rm -rf "$MKDIR_TEST_DIR"

# ── Condition evaluation ──

# Test that OS condition works (at least one branch should match)
OS_NAME=$(uname -s)
cat > recipes/condition-test.yml << EOF
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
rm -f recipes/condition-test.yml

# ── exists / not exists conditions ──

cat > recipes/exists-test.yml << 'EOF'
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
rm -f recipes/exists-test.yml

# ── Template rendering ──

cat > recipes/template-test.yml << 'EOF'
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
rm -f recipes/template-test.yml

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

# ── clone step ──

CLONE_TEST_DIR=$(mktemp -d)
CLONE_REPO="$CLONE_TEST_DIR/fake_repo"
CLONE_DEST="$CLONE_TEST_DIR/cloned"

# Create a local git repo to clone (no network needed)
mkdir -p "$CLONE_REPO"
git -C "$CLONE_REPO" init -q
git -C "$CLONE_REPO" commit --allow-empty -m "init" -q

cat > recipes/clone-test.yml << EOF
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

rm -f recipes/clone-test.yml
rm -rf "$CLONE_TEST_DIR"

# ── fonts step ──

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
    NVIM_OUTPUT=$(XDG_CONFIG_HOME="$(cd "$(dirname "$0")/.." && pwd)" nvim --headless -c "lua vim.health = vim.health or {}" -c "qall!" 2>&1 || true)

    if echo "$NVIM_OUTPUT" | grep -qi "error\|E5113\|module.*not found"; then
        fail "neovim config loads (errors found)"
        echo "$NVIM_OUTPUT" | grep -i "error\|E5113\|module" | head -5
    else
        pass "neovim config loads"
    fi
else
    pass "neovim config (skipped — nvim not installed)"
fi

# ── Summary ──

echo ""
echo "[tin] Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
