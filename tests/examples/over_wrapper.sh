#!/usr/bin/env bash
# Runs the tests of the example libraries over the wrapper of tests/support/wrapper.goose, which changes every byte
# and delays Opened by one pass, with no change to either library's source. The wrapper holds one inner loop per
# process, so each scenario of each test runs in its own process: `goose run <test> -- <scenario>`.
# The line client and the echo server, which need only the core, also run on the core-only loop of tests/support/core_only.goose.
# Usage: tests/examples/over_wrapper.sh
set -u
cd "$(dirname "$0")/../.."

# each test file and its scenarios: the number is the SCENARIOS constant of the test (one scenario without it)
tests=()
for file in tests/examples/*_test.goose; do
    n=$(sed -n 's/^let SCENARIOS = \([0-9][0-9]*\);.*/\1/p' "$file" | head -n 1)
    tests+=("$file:${n:-1}")
done
# The in-memory loop's wake capability uses a thread queue, which `goose run` (JIT) refuses: such a test is built once and its binary run.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
run_scenario() {
    local file="$1"; shift
    local out code bin
    out=$(goose run "$file" -- "$@" 2>&1)
    code=$?
    if [ $code -ne 0 ] && grep -q "JIT mode does not support threads" <<<"$out"; then
        bin="$tmp/$(echo "$file" | tr '/.' '__')"
        [ -x "$bin" ] || goose build "$file" -o "$bin" >/dev/null 2>&1
        out=$("$bin" "$@" 2>&1)
        code=$?
    fi
    run_out="$out"
    return $code
}
failed=0
ran=0
for entry in "${tests[@]}"; do
    file="${entry%%:*}"
    n="${entry##*:}"
    for ((i = 0; i < n; i++)); do
        run_scenario "$file" "$i"; code=$?; out="$run_out"
        ran=$((ran + 1))
        if [ $code -ne 0 ]; then
            echo "FAIL  $file scenario $i (exit $code)"
            echo "$out" | grep -vE "warning|\^~|as i64" | sed 's/^/      /' | head -n 8
            failed=$((failed + 1))
        fi
    done
done

# a library that needs only the core also runs on the loop that supplies only the core
core_ran=0
for file in tests/examples/lineclient_test.goose tests/examples/echo_test.goose tests/examples/forward_test.goose; do
    n=$(sed -n 's/^let SCENARIOS = \([0-9][0-9]*\);.*/\1/p' "$file" | head -n 1)
    for ((i = 0; i < n; i++)); do
        run_scenario "$file" "$i" core-only; code=$?; out="$run_out"
        core_ran=$((core_ran + 1))
        if [ $code -ne 0 ]; then
            echo "FAIL  $file scenario $i on the core-only loop (exit $code)"
            echo "$out" | grep -vE "warning|\^~|as i64" | sed 's/^/      /' | head -n 8
            failed=$((failed + 1))
        fi
    done
done
echo "$ran scenarios over the wrapper and $core_ran on the core-only loop, $failed failed"
[ $failed -eq 0 ]
