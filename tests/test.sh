#!/bin/bash
set -euo pipefail

PASSED=0
FAILED=0
TIN="./zig-out/bin/tin"

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

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

export TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT"
export TIN_DIR="$TEST_ROOT/.tin"

mkdir -p "$TIN_DIR"
cp -r recipes "$TIN_DIR/"
cp -r assets "$TIN_DIR/"
mkdir -p "$TIN_DIR/src"
cp -r src/schemas "$TIN_DIR/src/"
cat > "$TIN_DIR/tinrc.yml" << 'EOF'
identity:
  name: Your Name
  email: you@example.com

symlinks:
  shell:
    - source: assets/.zshrc
      target: ~/.zshrc

  copy:
    - source: assets/env.example
      target: ~/.config/tin/env.example
      copy: true

install:
  - link
  - fonts
EOF

trap "rm -rf $TEST_ROOT" EXIT


if zig build 2>/dev/null; then
    pass "zig build"
else
    fail "zig build"
fi



if $TIN help >/dev/null 2>&1; then
    pass "tin help"
else
    fail "tin help"
fi

if $TIN heal >/dev/null 2>&1; then
    pass "tin heal"
else
    fail "tin heal"
fi

if $TIN recipe 2>&1 | grep -q "git"; then
    pass "tin recipe (lists recipes)"
else
    fail "tin recipe (lists recipes)"
fi


if $TIN heal 2>&1 | grep -q "zshrc"; then
    pass "tinrc.yml symlinks parsed"
else
    fail "tinrc.yml symlinks parsed"
fi


TEST_DIR=$(mktemp -d)
TEST_SOURCE="$TEST_DIR/source_file"
TEST_TARGET="$TEST_DIR/target_link"
echo "test content" > "$TEST_SOURCE"

LINKED_COUNT=$($TIN heal 2>&1 | grep -c "\[ok\]\|not linked\|wrong target\|broken" || true)
if [ "$LINKED_COUNT" -gt 0 ]; then
    pass "tin heal reports symlink state ($LINKED_COUNT entries)"
else
    fail "tin heal reports symlink state"
fi

rm -rf "$TEST_DIR"


if $TIN recipe git 2>&1 | grep -q "recipe complete"; then
    pass "tin recipe git (executes)"
else
    fail "tin recipe git (executes)"
fi

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


mkdir -p "$HOME/.config/tin/recipes"
cat > "$HOME/.config/tin/recipes/layer-personal.yml" << 'EOF'
name: layer-personal
description: Only in the personal config layer

steps:
  - name: Personal step
    run: echo personal
EOF

cat > "$HOME/.config/tin/recipes/mkdir-test.yml" << 'EOF'
name: mkdir-test
description: Personal override of a repo recipe

steps:
  - mkdir: $MKDIR_TEST_DIR
EOF

if $TIN recipe layer-personal 2>&1 | grep -q "recipe complete"; then
    pass "personal-layer recipe executes"
else
    fail "personal-layer recipe executes"
fi

LAYER_LIST=$($TIN recipe 2>&1)
if echo "$LAYER_LIST" | grep -q "layer-personal.*\[config\]"; then
    pass "personal-layer recipe listed as [config]"
else
    fail "personal-layer recipe listed as [config]"
fi

if echo "$LAYER_LIST" | grep -q "git.*\[repo\]"; then
    pass "repo recipe listed as [repo]"
else
    fail "repo recipe listed as [repo]"
fi

MKDIR_TEST_DIR=$(mktemp -d)/tin_mkdir_test
if $TIN recipe mkdir-test 2>&1 | grep -q "Personal override"; then
    pass "personal layer shadows repo recipe"
else
    fail "personal layer shadows repo recipe"
fi
rm -rf "$HOME/.config/tin/recipes"

MKDIR_TEST_DIR=$(mktemp -d)/tin_mkdir_test
cat > /tmp/tin_test_recipe.yml << 'EOF'
name: mkdir-test
steps:
  - mkdir: MKDIR_PLACEHOLDER
EOF
sed -i.bak "s|MKDIR_PLACEHOLDER|$MKDIR_TEST_DIR|" /tmp/tin_test_recipe.yml 2>/dev/null || \
    sed -i '' "s|MKDIR_PLACEHOLDER|$MKDIR_TEST_DIR|" /tmp/tin_test_recipe.yml

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


cat > "$TIN_DIR/recipes/exists-test.yml" << 'EOF'
name: exists-test
steps:
  - name: Root exists
    run: echo "root exists"
    if: exists('/')
  - name: Missing path
    run: echo "should not run"
    if: exists('/nonexistent_tin_test_path')
  - name: Not exists check
    run: echo "not exists works"
    if: "!exists('/nonexistent_tin_test_path')"
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


LINK_TEST_DIR=$(mktemp -d)
LINK_SOURCE="$LINK_TEST_DIR/source_file"
LINK_TARGET="$LINK_TEST_DIR/target_link"
echo "link test content" > "$LINK_SOURCE"

ln -sf "$LINK_SOURCE" "$LINK_TARGET"
if [ -L "$LINK_TARGET" ] && [ "$(readlink "$LINK_TARGET")" = "$LINK_SOURCE" ]; then
    pass "symlink creation works"
else
    fail "symlink creation works"
fi

if $TIN link 2>&1 | grep -q "linking\|skip\|link"; then
    pass "tin link runs"
else
    fail "tin link runs"
fi

if $TIN unlink 2>&1 | grep -q "unlink"; then
    pass "tin unlink runs"
else
    fail "tin unlink runs"
fi

if $TIN link 2>&1 | grep -q "link"; then
    pass "tin link after unlink"
else
    fail "tin link after unlink"
fi

rm -rf "$LINK_TEST_DIR"


COPY_SOURCE="$TIN_DIR/assets/env.example"
COPY_TARGET="$HOME/.config/tin/env.example"

if [ -f "$COPY_TARGET" ] && [ ! -L "$COPY_TARGET" ]; then
    pass "tin link installs a copy as a real file"
else
    fail "tin link installs a copy as a real file"
fi

if cmp -s "$COPY_SOURCE" "$COPY_TARGET"; then
    pass "copy matches its source"
else
    fail "copy matches its source"
fi

echo "drifted" > "$COPY_TARGET"
if $TIN heal 2>&1 | grep -q "refreshed"; then
    pass "tin heal refreshes a stale copy"
else
    fail "tin heal refreshes a stale copy"
fi

if cmp -s "$COPY_SOURCE" "$COPY_TARGET" && [ ! -L "$COPY_TARGET" ]; then
    pass "refreshed copy matches its source"
else
    fail "refreshed copy matches its source"
fi

if $TIN unlink >/dev/null 2>&1 && [ ! -e "$COPY_TARGET" ]; then
    pass "tin unlink removes a copy"
else
    fail "tin unlink removes a copy"
fi

$TIN link >/dev/null 2>&1


HEAL_TEST_DIR=$(mktemp -d)
HEAL_SOURCE="$HEAL_TEST_DIR/heal_source"
HEAL_TARGET="$HEAL_TEST_DIR/heal_target"
ln -sf "$HEAL_SOURCE" "$HEAL_TARGET"

if $TIN heal 2>&1 | grep -q "healthy"; then
    pass "tin heal reports healthy when nothing broken"
else
    fail "tin heal reports healthy when nothing broken"
fi

rm -rf "$HEAL_TEST_DIR"

zshrc_source="$TIN_DIR/assets/.zshrc"
ln -sf "/wrong/target" "$HOME/.zshrc"
$TIN heal >/dev/null 2>&1
if [ "$(readlink "$HOME/.zshrc")" = "$zshrc_source" ]; then
    pass "tin heal repairs wrong-target symlink"
else
    fail "tin heal repairs wrong-target symlink"
fi


CLONE_TEST_DIR=$(mktemp -d)
CLONE_REPO="$CLONE_TEST_DIR/fake_repo"
CLONE_DEST="$CLONE_TEST_DIR/cloned"

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

if $TIN recipe clone-test 2>&1 | grep -q "skip clone"; then
    pass "clone step skips existing"
else
    fail "clone step skips existing"
fi

rm -f "$TIN_DIR/recipes/clone-test.yml"
rm -rf "$CLONE_TEST_DIR"


mkdir -p "$HOME/Library/Fonts"
if $TIN fonts 2>&1 | grep -q "fonts\|copy\|skipped"; then
    pass "tin fonts runs"
else
    fail "tin fonts runs"
fi


if $TIN install 2>&1 | grep -q "install complete"; then
    pass "tin install (full flow)"
else
    fail "tin install (full flow)"
fi


if command -v nvim &>/dev/null; then
    NVIM_OUTPUT=$(run_bounded 60 env XDG_CONFIG_HOME="$(cd "$(dirname "$0")/.." && pwd)" nvim --headless -c "lua vim.health = vim.health or {}" -c "qall!" 2>&1 || true)
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

echo ""
echo "[tin] Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
