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
failed=0
ran=0
for entry in "${tests[@]}"; do
    file="${entry%%:*}"
    n="${entry##*:}"
    for ((i = 0; i < n; i++)); do
        out=$(goose run "$file" -- "$i" 2>&1)
        code=$?
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
for file in tests/examples/lineclient_test.goose tests/examples/echo_test.goose; do
    n=$(sed -n 's/^let SCENARIOS = \([0-9][0-9]*\);.*/\1/p' "$file" | head -n 1)
    for ((i = 0; i < n; i++)); do
        out=$(goose run "$file" -- "$i" core-only 2>&1)
        code=$?
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
