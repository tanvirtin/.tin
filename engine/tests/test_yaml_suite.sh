#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BIN="${1:-}"
CORPUS="${2:-${TIN_YAML_CORPUS_DIR:-}}"
TIMEOUT="${TIN_YAML_TIMEOUT:-10}"
PIN_FILE="$SCRIPT_DIR/yaml-suite-revision.txt"

if [ -z "$BIN" ]; then
    echo "usage: test_yaml_suite.sh <test_yaml_one-binary> [corpus-dir]" >&2
    echo "  corpus-dir may also be supplied with TIN_YAML_CORPUS_DIR" >&2
    exit 1
fi

if [ -z "$CORPUS" ]; then
    echo "SKIP: no official YAML corpus provided (pass a corpus-dir or set TIN_YAML_CORPUS_DIR)"
    exit 0
fi

PIN=""
if [ -f "$PIN_FILE" ]; then
    PIN=$(sed -n 's/^revision=//p' "$PIN_FILE" | head -n1)
fi

if [ ! -f "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "ERROR: binary not found or not executable: $BIN" >&2
    exit 1
fi

if [ ! -d "$CORPUS" ]; then
    echo "ERROR: corpus directory not found: $CORPUS" >&2
    exit 1
fi

ACTUAL="unverified"
if [ -e "$CORPUS/.git" ] && command -v git >/dev/null 2>&1; then
    ACTUAL=$(git -C "$CORPUS" rev-parse HEAD 2>/dev/null || echo "unverified")
    if [ -n "$PIN" ] && [ "$ACTUAL" != "unverified" ] && [ "$ACTUAL" != "$PIN" ]; then
        echo "ERROR: corpus revision $ACTUAL does not match pinned $PIN" >&2
        exit 1
    fi
fi

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
find "$CORPUS" -name .git -prune -o -name in.yaml -type f -print | sort > "$LIST"
COUNT=$(wc -l < "$LIST" | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: no in.yaml cases found in corpus (empty or wrong layout): $CORPUS" >&2
    exit 1
fi

TIMEOUT_CMD=""
TIMEOUT_RC=-1
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
    TIMEOUT_RC=124
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
    TIMEOUT_RC=124
else
    TIMEOUT_RC=142
fi

run_case() {
    local file="$1"
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$TIMEOUT" "$BIN" "$file" 2>/dev/null
    else
        perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" "$file" 2>/dev/null
    fi
}

classify() {
    local rc="$1"
    if [ "$rc" -eq 0 ]; then
        echo "accept"
    elif [ "$rc" -eq 2 ]; then
        echo "reject"
    elif [ "$rc" -eq "$TIMEOUT_RC" ]; then
        echo "timeout"
    else
        echo "crash (exit $rc)"
    fi
}

echo "YAML suite corpus: $CORPUS"
echo "YAML suite revision: ${PIN:-unpinned} (corpus: $ACTUAL)"
echo "Cases: $COUNT"

accept_total=0
accept_pass=0
reject_total=0
reject_pass=0
failed=0

while IFS= read -r y; do
    case_dir=$(dirname "$y")
    id=${case_dir#"$CORPUS"/}
    if [ -f "$case_dir/error" ]; then
        expected="reject"
        reject_total=$((reject_total + 1))
    else
        expected="accept"
        accept_total=$((accept_total + 1))
    fi
    rc=0
    run_case "$y" || rc=$?
    got=$(classify "$rc")
    if [ "$expected" = "accept" ]; then
        if [ "$got" = "accept" ]; then
            accept_pass=$((accept_pass + 1))
        else
            failed=$((failed + 1))
            echo "FAIL $id: expected accept, got $got"
        fi
    else
        if [ "$got" = "reject" ]; then
            reject_pass=$((reject_pass + 1))
        else
            failed=$((failed + 1))
            echo "FAIL $id: expected reject, got $got"
        fi
    fi
done < "$LIST"

passed=$((accept_pass + reject_pass))
echo "Accept: $accept_pass/$accept_total  Reject: $reject_pass/$reject_total  Total: $passed/$COUNT"

if [ "$failed" -gt 0 ]; then
    echo "Failing: $failed"
    exit 1
fi
