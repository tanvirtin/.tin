#!/bin/bash
set -euo pipefail

BINARY="${1:-./test_yaml_one}"
TEST_DIR="${2:-/tmp/yaml-test-data}"

if [ ! -d "$TEST_DIR" ]; then
    echo "Downloading YAML test suite..."
    git clone --branch data --depth 1 https://github.com/yaml/yaml-test-suite.git "$TEST_DIR"
fi

# Use timeout (Linux/CI) or perl (macOS) for per-test time limits
run_with_timeout() {
    if command -v timeout &>/dev/null; then
        timeout 2 "$@" 2>/dev/null || echo "TIMEOUT"
    else
        perl -e 'alarm 2; exec @ARGV' "$@" 2>/dev/null || echo "TIMEOUT"
    fi
}

vp=0; vf=0; ep=0; ef=0; vt=0; et=0; failing=""
for dir in "$TEST_DIR"/*/; do
    id=$(basename "$dir"); y="$dir/in.yaml"; [ ! -f "$y" ] && continue
    ee=false; [ -f "$dir/error" ] && ee=true
    r=$(run_with_timeout "$BINARY" "$y")
    if [ "$ee" = true ]; then et=$((et+1))
        if [ "$r" = "ERROR" ] || [ "$r" = "TIMEOUT" ]; then ep=$((ep+1)); else ef=$((ef+1)); failing="$failing  $id (should error)\n"; fi
    else vt=$((vt+1))
        if [ "$r" = "OK" ]; then vp=$((vp+1))
        elif [ "$r" = "TIMEOUT" ]; then failing="$failing  $id (timeout)\n"; vf=$((vf+1))
        else vf=$((vf+1)); failing="$failing  $id (should pass)\n"; fi
    fi
done

total=$((vp + ep))
expected=$((vt + et))
echo "Valid: $vp/$vt  Error: $ep/$et  Total: $total/$expected"
[ -n "$failing" ] && echo "Failing ($((vf + ef))):" && printf "$failing"

if [ "$total" -ne "$expected" ]; then
    exit 1
fi
