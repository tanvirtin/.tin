#!/bin/bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: test.sh <absolute-tin-binary> [runtime-root]" >&2
    exit 2
fi

TIN_ARG="$1"
RUNTIME_ARG="${2:-}"

case "$TIN_ARG" in
    /*) TIN="$TIN_ARG" ;;
    *) TIN="$(pwd)/$TIN_ARG" ;;
esac

if [ ! -x "$TIN" ]; then
    echo "test.sh: tin binary is not executable: $TIN" >&2
    exit 2
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENGINE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

if [ -z "$RUNTIME_ARG" ]; then
    RUNTIME_ROOT="$(CDPATH= cd -- "$ENGINE_DIR/.." && pwd)"
else
    case "$RUNTIME_ARG" in
        /*) RUNTIME_ROOT="$RUNTIME_ARG" ;;
        *) RUNTIME_ROOT="$(CDPATH= cd -- "$RUNTIME_ARG" && pwd)" ;;
    esac
fi

RECIPES_SRC="$RUNTIME_ROOT/environment/recipes"
CONFIG_SRC="$RUNTIME_ROOT/environment/config"
SCHEMAS_SRC="$RUNTIME_ROOT/engine/src/schemas"

for fixture in "$RECIPES_SRC" "$CONFIG_SRC" "$SCHEMAS_SRC"; do
    if [ ! -d "$fixture" ]; then
        echo "test.sh: missing runtime fixture: $fixture" >&2
        exit 2
    fi
done

unset TIN_ARTIFACTS TIN_RECIPES TIN_CONFIG
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

export GIT_CONFIG_NOSYSTEM=1
export GIT_EDITOR=true
export GIT_MERGE_AUTOEDIT=no
export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="tin-test"
export GIT_AUTHOR_EMAIL="tin-test@example.invalid"
export GIT_COMMITTER_NAME="tin-test"
export GIT_COMMITTER_EMAIL="tin-test@example.invalid"

PASSED=0
FAILED=0

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

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT"
export TIN_DIR="$TEST_ROOT/.tin"
export TIN_ARTIFACTS="$TEST_ROOT/.config/tin/artifacts"
export TIN_RECIPES="$TEST_ROOT/.config/tin/recipes"

mkdir -p "$TIN_DIR/environment" "$TIN_DIR/engine/src" "$HOME/.config/tin"
cp -R "$RECIPES_SRC" "$TIN_DIR/environment/recipes"
cp -R "$CONFIG_SRC" "$TIN_DIR/environment/config"
cp -R "$SCHEMAS_SRC" "$TIN_DIR/engine/src/schemas"
cat > "$HOME/.config/tin/tinrc.yml" << 'EOF'
identity:
  name: Your Name
  email: you@example.com

symlinks:
  shell:
    - source: environment/config/.zshrc
      target: ~/.zshrc

  copy:
    - source: environment/config/.tmux.conf
      target: ~/.config/tin/test-copy.conf
      copy: true

install:
  - link
  - fonts
EOF

NOCFG_HOME="$(mktemp -d)"
NOCFG_TIN="$NOCFG_HOME/.tin"
mkdir -p "$NOCFG_TIN"
for cmd in install link heal; do
    if HOME="$NOCFG_HOME" TIN_DIR="$NOCFG_TIN" TIN_ARTIFACTS="$NOCFG_HOME/.config/tin/artifacts" TIN_RECIPES="$NOCFG_HOME/.config/tin/recipes" "$TIN" "$cmd" >/dev/null 2>&1; then
        pass "tin $cmd without tinrc.yml"
    else
        fail "tin $cmd without tinrc.yml"
    fi
done
rm -rf "$NOCFG_HOME"

CFG_HOME="$(mktemp -d)"
CFG_TIN="$CFG_HOME/.tin"
mkdir -p "$CFG_TIN/engine/src" "$CFG_TIN/environment/config" "$CFG_HOME/.config/tin"
cp -R "$SCHEMAS_SRC" "$CFG_TIN/engine/src/schemas"
echo "repo" > "$CFG_TIN/environment/config/repo.txt"
echo "personal" > "$CFG_TIN/environment/config/personal.txt"
cat > "$CFG_TIN/tinrc.yml" << 'EOF'
symlinks:
  shell:
    - source: environment/config/repo.txt
      target: ~/.repo-link
EOF

REPO_ONLY_OUT="$(HOME="$CFG_HOME" TIN_DIR="$CFG_TIN" TIN_ARTIFACTS="$CFG_HOME/.config/tin/artifacts" TIN_RECIPES="$CFG_HOME/.config/tin/recipes" "$TIN" heal 2>&1 || true)"
if echo "$REPO_ONLY_OUT" | grep -q "repo.txt"; then
    pass "config: repo tinrc used when no personal config"
else
    fail "config: repo tinrc used when no personal config"
fi

cat > "$CFG_HOME/.config/tin/tinrc.yml" << 'EOF'
symlinks:
  shell:
    - source: environment/config/personal.txt
      target: ~/.personal-link
EOF

PRECEDENCE_OUT="$(HOME="$CFG_HOME" TIN_DIR="$CFG_TIN" TIN_ARTIFACTS="$CFG_HOME/.config/tin/artifacts" TIN_RECIPES="$CFG_HOME/.config/tin/recipes" "$TIN" heal 2>&1 || true)"
if echo "$PRECEDENCE_OUT" | grep -q "personal.txt" && ! echo "$PRECEDENCE_OUT" | grep -q "repo.txt"; then
    pass "config: personal tinrc replaces repo tinrc"
else
    fail "config: personal tinrc replaces repo tinrc"
fi

printf 'symlinks: [unterminated\n' > "$CFG_HOME/.config/tin/tinrc.yml"
set +e
BAD_CFG_OUT="$(HOME="$CFG_HOME" TIN_DIR="$CFG_TIN" TIN_ARTIFACTS="$CFG_HOME/.config/tin/artifacts" TIN_RECIPES="$CFG_HOME/.config/tin/recipes" "$TIN" heal 2>&1)"
BAD_CFG_RC=$?
set -e
if [ "$BAD_CFG_RC" -ne 0 ] && echo "$BAD_CFG_OUT" | grep -qiE "tinrc|config"; then
    pass "config: invalid personal config is reported, not ignored"
else
    fail "config: invalid personal config is reported, not ignored"
fi
rm -rf "$CFG_HOME"

if "$TIN" help >/dev/null 2>&1; then
    pass "tin help"
else
    fail "tin help"
fi

if "$TIN" heal >/dev/null 2>&1; then
    pass "tin heal"
else
    fail "tin heal"
fi

if "$TIN" recipe 2>&1 | grep -q "git"; then
    pass "tin recipe (lists recipes)"
else
    fail "tin recipe (lists recipes)"
fi

if "$TIN" heal 2>&1 | grep -q "zshrc"; then
    pass "tinrc.yml symlinks parsed"
else
    fail "tinrc.yml symlinks parsed"
fi

LINKED_COUNT=$("$TIN" heal 2>&1 | grep -c "\[ok\]\|not linked\|wrong target\|broken" || true)
if [ "$LINKED_COUNT" -gt 0 ]; then
    pass "tin heal reports symlink state ($LINKED_COUNT entries)"
else
    fail "tin heal reports symlink state"
fi

if "$TIN" recipe git 2>&1 | grep -q "recipe complete"; then
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

if "$TIN" recipe layer-personal 2>&1 | grep -q "recipe complete"; then
    pass "personal-layer recipe executes"
else
    fail "personal-layer recipe executes"
fi

LAYER_LIST=$("$TIN" recipe 2>&1)
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
if "$TIN" recipe mkdir-test 2>&1 | grep -q "Personal override"; then
    pass "personal layer shadows repo recipe"
else
    fail "personal layer shadows repo recipe"
fi
rm -rf "$HOME/.config/tin/recipes"

MKDIR_TEST_DIR=$(mktemp -d)/tin_mkdir_test
cat > "$TIN_DIR/environment/recipes/mkdir-test.yml" << EOF
name: mkdir-test
steps:
  - mkdir: $MKDIR_TEST_DIR
EOF

if "$TIN" recipe mkdir-test 2>&1 | grep -q "recipe complete"; then
    if [ -d "$MKDIR_TEST_DIR" ]; then
        pass "mkdir step creates directory"
    else
        fail "mkdir step creates directory"
    fi
else
    fail "mkdir step (recipe failed)"
fi
rm -f "$TIN_DIR/environment/recipes/mkdir-test.yml"
rm -rf "$MKDIR_TEST_DIR"

OS_NAME=$(uname -s)
cat > "$TIN_DIR/environment/recipes/condition-test.yml" << EOF
name: condition-test
steps:
  - name: OS match
    run: echo "TIN_COND_MATCHED"
    if: os == '$([ "$OS_NAME" = "Darwin" ] && echo darwin || echo linux)'
  - name: OS no match
    run: echo "TIN_COND_UNEXPECTED"
    if: os == 'nonexistent_os'
EOF

COND_OUTPUT=$("$TIN" recipe condition-test 2>&1)
if echo "$COND_OUTPUT" | grep -q "TIN_COND_MATCHED"; then
    pass "condition: os == (matched)"
else
    fail "condition: os == (matched)"
fi
if echo "$COND_OUTPUT" | grep -q "TIN_COND_UNEXPECTED"; then
    fail "condition: os == (skipped)"
else
    pass "condition: os == (skipped)"
fi
rm -f "$TIN_DIR/environment/recipes/condition-test.yml"

cat > "$TIN_DIR/environment/recipes/exists-test.yml" << 'EOF'
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

EXISTS_OUTPUT=$("$TIN" recipe exists-test 2>&1)
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
rm -f "$TIN_DIR/environment/recipes/exists-test.yml"

cat > "$TIN_DIR/environment/recipes/template-test.yml" << 'EOF'
name: template-test
steps:
  - name: Render identity
    run: echo "Hello {{ identity.name }}"
EOF

TMPL_OUTPUT=$("$TIN" recipe template-test 2>&1)
if echo "$TMPL_OUTPUT" | grep -q "recipe complete"; then
    pass "template rendering"
else
    fail "template rendering"
fi
rm -f "$TIN_DIR/environment/recipes/template-test.yml"

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

if "$TIN" link 2>&1 | grep -q "linking\|skip\|link"; then
    pass "tin link runs"
else
    fail "tin link runs"
fi

if "$TIN" unlink 2>&1 | grep -q "unlink"; then
    pass "tin unlink runs"
else
    fail "tin unlink runs"
fi

if "$TIN" link 2>&1 | grep -q "link"; then
    pass "tin link after unlink"
else
    fail "tin link after unlink"
fi

rm -rf "$LINK_TEST_DIR"

COPY_SOURCE="$TIN_DIR/environment/config/.tmux.conf"
COPY_TARGET="$HOME/.config/tin/test-copy.conf"

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
if "$TIN" heal 2>&1 | grep -q "refreshed"; then
    pass "tin heal refreshes a stale copy"
else
    fail "tin heal refreshes a stale copy"
fi

if cmp -s "$COPY_SOURCE" "$COPY_TARGET" && [ ! -L "$COPY_TARGET" ]; then
    pass "refreshed copy matches its source"
else
    fail "refreshed copy matches its source"
fi

if "$TIN" unlink >/dev/null 2>&1 && [ ! -e "$COPY_TARGET" ]; then
    pass "tin unlink removes a copy"
else
    fail "tin unlink removes a copy"
fi

"$TIN" link >/dev/null 2>&1

HEAL_TEST_DIR=$(mktemp -d)
HEAL_SOURCE="$HEAL_TEST_DIR/heal_source"
HEAL_TARGET="$HEAL_TEST_DIR/heal_target"
ln -sf "$HEAL_SOURCE" "$HEAL_TARGET"

if "$TIN" heal 2>&1 | grep -q "healthy"; then
    pass "tin heal reports healthy when nothing broken"
else
    fail "tin heal reports healthy when nothing broken"
fi

rm -rf "$HEAL_TEST_DIR"

zshrc_source="$TIN_DIR/environment/config/.zshrc"
ln -sf "/wrong/target" "$HOME/.zshrc"
"$TIN" heal >/dev/null 2>&1
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

cat > "$TIN_DIR/environment/recipes/clone-test.yml" << EOF
name: clone-test
steps:
  - clone: $CLONE_REPO
    to: $CLONE_DEST
EOF

if "$TIN" recipe clone-test 2>&1 | grep -q "recipe complete"; then
    if [ -d "$CLONE_DEST/.git" ]; then
        pass "clone step creates repo"
    else
        fail "clone step creates repo"
    fi
else
    fail "clone step (recipe failed)"
fi

if "$TIN" recipe clone-test 2>&1 | grep -q "skip clone"; then
    pass "clone step skips existing"
else
    fail "clone step skips existing"
fi

rm -f "$TIN_DIR/environment/recipes/clone-test.yml"
rm -rf "$CLONE_TEST_DIR"

ARTIFACTS_DIR="$HOME/.config/tin/artifacts"
mkdir -p "$ARTIFACTS_DIR/skills/demo" "$ARTIFACTS_DIR/rules"
cat > "$ARTIFACTS_DIR/rules/demo-rule.yml" << 'EOF'
description: A demo rule
content: |
  - do the thing
EOF
cat > "$ARTIFACTS_DIR/skills/demo/plan.yml" << 'EOF'
description: A demo skill
include:
  - demo-rule
system: |
  {{ demo-rule }}
EOF

if "$TIN" artifact validate 2>&1 | grep -q "all references valid"; then
    pass "artifact validate accepts valid artifacts"
else
    fail "artifact validate accepts valid artifacts"
fi

if "$TIN" artifact list 2>&1 | grep -q "demo/plan"; then
    pass "artifact list shows discovered skill"
else
    fail "artifact list shows discovered skill"
fi

cat > "$ARTIFACTS_DIR/skills/demo/broken.yml" << 'EOF'
description: A skill with a broken include
include:
  - does-not-exist
system: |
  {{ does-not-exist }}
EOF

broken_out=$("$TIN" artifact validate 2>&1 || true)
if echo "$broken_out" | grep -q "undefined reference: does-not-exist"; then
    pass "artifact validate rejects a broken include"
else
    fail "artifact validate rejects a broken include"
fi
rm -f "$ARTIFACTS_DIR/skills/demo/broken.yml"

MCP_DIR="$ARTIFACTS_DIR/mcp"
DIALECT_DIR="$ARTIFACTS_DIR/dialects"
mkdir -p "$MCP_DIR" "$DIALECT_DIR"
cat > "$MCP_DIR/mem0.yml" << 'EOF'
type: http
url: https://mcp.mem0.ai/mcp
headers:
  Authorization: MEM0_API_KEY
secrets:
  - headers.Authorization
EOF
cat > "$DIALECT_DIR/cursor.yml" << 'EOF'
container: mcpServers
format: json
transport: inferred
command_style: scalar
secret:
  style: env_ref
EOF
cat > "$DIALECT_DIR/codex.yml" << 'EOF'
container: mcp_servers
format: toml
transport: inferred
command_style: scalar
secret:
  style: env_var_name
  key: bearer_token_env_var
EOF

cat >> "$HOME/.config/tin/tinrc.yml" << 'EOF'

runtimes:
  cursor:
    mcp: ~/.cursor/mcp.json
    dialect: cursor
  codex:
    mcp: ~/.codex/config.toml
    dialect: codex
EOF

mkdir -p "$HOME/.cursor" "$HOME/.codex"
echo '{"mcpServers":{"other":{"command":"keep-me"}},"unrelated":true}' > "$HOME/.cursor/mcp.json"
printf 'model = "gpt-5"\n' > "$HOME/.codex/config.toml"

if "$TIN" mcp list 2>&1 | grep -q "mem0"; then
    pass "tin mcp list shows declared server"
else
    fail "tin mcp list shows declared server"
fi

if "$TIN" mcp diff 2>&1 | grep -q "would update"; then
    pass "tin mcp diff reports pending changes"
else
    fail "tin mcp diff reports pending changes"
fi

if "$TIN" mcp apply 2>&1 | grep -qE "wrote|updated"; then
    pass "tin mcp apply writes runtime configs"
else
    fail "tin mcp apply writes runtime configs"
fi

if grep -q "keep-me" "$HOME/.cursor/mcp.json" && grep -q "mcp.mem0.ai" "$HOME/.cursor/mcp.json"; then
    pass "mcp json merge preserves foreign entries"
else
    fail "mcp json merge preserves foreign entries"
fi

if grep -q '\${env:MEM0_API_KEY}' "$HOME/.cursor/mcp.json"; then
    pass "mcp env_ref secret rewritten"
else
    fail "mcp env_ref secret rewritten"
fi

if grep -q 'bearer_token_env_var = "MEM0_API_KEY"' "$HOME/.codex/config.toml" && grep -q 'model = "gpt-5"' "$HOME/.codex/config.toml"; then
    pass "mcp toml merge keeps unrelated keys and hoists secret"
else
    fail "mcp toml merge keeps unrelated keys and hoists secret"
fi

MCP_BEFORE=$(cat "$HOME/.cursor/mcp.json")
"$TIN" mcp apply >/dev/null 2>&1
MCP_AFTER=$(cat "$HOME/.cursor/mcp.json")
if [ "$MCP_BEFORE" = "$MCP_AFTER" ]; then
    pass "tin mcp apply is idempotent"
else
    fail "tin mcp apply is idempotent"
fi

rm -rf "$MCP_DIR" "$DIALECT_DIR" "$HOME/.cursor" "$HOME/.codex"

cat > "$TIN_DIR/environment/recipes/apply-steps.yml" << 'EOF'
name: apply-steps
steps:
  - name: link
    link: true
  - name: fonts
    fonts: true
EOF

if "$TIN" recipe apply-steps 2>&1 | grep -q "linking complete"; then
    pass "recipe link: step links symlinks"
else
    fail "recipe link: step links symlinks"
fi

if "$TIN" recipe apply-steps 2>&1 | grep -qE "fonts installed|fonts up to date"; then
    pass "recipe fonts: step installs fonts"
else
    fail "recipe fonts: step installs fonts"
fi
rm -f "$TIN_DIR/environment/recipes/apply-steps.yml"

mkdir -p "$HOME/Library/Fonts"
if "$TIN" fonts 2>&1 | grep -q "fonts\|copy\|skipped"; then
    pass "tin fonts runs"
else
    fail "tin fonts runs"
fi

if "$TIN" install 2>&1 | grep -q "install complete"; then
    pass "tin install (full flow)"
else
    fail "tin install (full flow)"
fi

echo ""
echo "[tin] Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
