#!/bin/bash
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER="$SCRIPT_DIR/test_yaml_suite.sh"
PIN_FILE="$SCRIPT_DIR/yaml-suite-revision.txt"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

FAKE="$WORK/fake_yaml_one"
cat > "$FAKE" <<'FAKE_EOF'
#!/bin/bash
set -u
f="${1:-}"
dir=$(dirname "$f")
base=$(basename "$dir")
case "$base" in
    *-crash) exit 3 ;;
    *-hang) exec sleep 30 ;;
    *-misaccept) exit 0 ;;
    *-misreject) exit 2 ;;
esac
if [ -f "$dir/error" ]; then
    exit 2
fi
exit 0
FAKE_EOF
chmod +x "$FAKE"

mkcase() { mkdir -p "$1"; printf 'a: 1\n' > "$1/in.yaml"; }
mkerr() { mkcase "$1"; : > "$1/error"; }

run_runner() {
    OUT="$WORK/out.txt"
    RC=0
    bash "$RUNNER" "$@" > "$OUT" 2>&1 || RC=$?
}

check_rc() {
    if [ "$RC" -eq "$1" ]; then ok "$2"; else no "$2 (exit $RC)"; sed 's/^/    | /' "$OUT"; fi
}

check_out() {
    if grep -qF -- "$1" "$OUT"; then ok "$2"; else no "$2"; sed 's/^/    | /' "$OUT"; fi
}

check_no_out() {
    if grep -qF -- "$1" "$OUT"; then no "$2"; sed 's/^/    | /' "$OUT"; else ok "$2"; fi
}

CORPUS="$WORK/ok"
mkcase "$CORPUS/ok-case"
mkerr "$CORPUS/err-case"
mkcase "$CORPUS/nested/00-ok"
mkerr "$CORPUS/nested/01-err"
run_runner "$FAKE" "$CORPUS"
check_rc 0 "accepted/rejected corpus passes"
check_out "Total: 4/4" "nested cases are discovered and counted"
check_no_out "FAIL" "passing corpus reports no failures"
PIN=$(sed -n 's/^revision=//p' "$PIN_FILE" | head -n1)
if [ -n "$PIN" ]; then check_out "$PIN" "runner reports the pinned revision"; fi

CORPUS="$WORK/crash-valid"
mkcase "$CORPUS/case-crash"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "crash on a valid case fails the run"
check_out "expected accept, got crash (exit 3)" "crash is classified as crash"

CORPUS="$WORK/crash-error"
mkerr "$CORPUS/err-crash"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "crash on a reject-expected case fails the run"
check_out "expected reject, got crash (exit 3)" "crash is never counted as expected rejection"

CORPUS="$WORK/timeout-valid"
mkcase "$CORPUS/case-hang"
export TIN_YAML_TIMEOUT=1
run_runner "$FAKE" "$CORPUS"
unset TIN_YAML_TIMEOUT
check_rc 1 "timeout on a valid case fails the run"
check_out "expected accept, got timeout" "timeout is classified as timeout"

CORPUS="$WORK/timeout-error"
mkerr "$CORPUS/err-hang"
export TIN_YAML_TIMEOUT=1
run_runner "$FAKE" "$CORPUS"
unset TIN_YAML_TIMEOUT
check_rc 1 "timeout on a reject-expected case fails the run"
check_out "expected reject, got timeout" "timeout is never counted as expected rejection"

CORPUS="$WORK/misaccept"
mkerr "$CORPUS/err-misaccept"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "accepting invalid YAML fails the run"
check_out "expected reject, got accept" "false accept is reported"

CORPUS="$WORK/misreject"
mkcase "$CORPUS/case-misreject"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "rejecting valid YAML fails the run"
check_out "expected accept, got reject" "false rejection is reported"

CORPUS="$WORK/empty"
mkdir -p "$CORPUS"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "empty corpus is rejected"
check_out "no in.yaml cases" "empty corpus is reported"

CORPUS="$WORK/wrong-layout"
mkdir -p "$CORPUS/src"
printf 'a: 1\n' > "$CORPUS/src/229Q.yaml"
run_runner "$FAKE" "$CORPUS"
check_rc 1 "wrong-layout corpus is rejected"
check_out "no in.yaml cases" "wrong layout is reported"

run_runner "$FAKE" "$WORK/does-not-exist"
check_rc 1 "missing corpus directory is rejected"
check_out "corpus directory not found" "missing corpus is reported"

run_runner "$WORK/no-such-binary" "$WORK/ok"
check_rc 1 "missing binary is rejected"
check_out "binary not found" "missing binary is reported"

run_runner "$FAKE"
check_rc 0 "no corpus is skipped locally"
check_out "SKIP" "skip is reported instead of a false 0/0 pass"

if command -v git >/dev/null 2>&1; then
    CORPUS="$WORK/git-revision"
    mkcase "$CORPUS/ok-case"
    git -C "$CORPUS" init -q
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com git -C "$CORPUS" add -A
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com git -C "$CORPUS" commit -qm init
    if [ -n "$PIN" ]; then
        run_runner "$FAKE" "$CORPUS"
        check_rc 1 "corpus revision mismatch is rejected"
        check_out "does not match pinned" "revision mismatch is reported"
    fi
fi

echo ""
echo "[yaml suite runner] Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
