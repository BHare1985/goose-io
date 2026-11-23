#!/usr/bin/env bash
# Shows that every conformance check can fail. For each row of tests/conformance/checks.tsv that names a fault,
# switches the in-memory event loop to that fault, runs the check's part, and requires the output to name the
# check as failed. A check that passes against its own fault is a defect in the suite.
# Also requires that with no fault every part passes (the same as run.sh).
# Usage: tests/conformance/faults.sh [check-name ...]   (default: every check)
set -u
cd "$(dirname "$0")/../.."

only=("$@")
want() {
    [ ${#only[@]} -eq 0 ] && return 0
    for n in "${only[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

# a time limit where the system has one (GNU timeout, or gtimeout from coreutils on macOS); without it the loop's own
# time limit ends a runaway check
limited() {
    if command -v timeout > /dev/null 2>&1; then timeout 120 "$@"
    elif command -v gtimeout > /dev/null 2>&1; then gtimeout 120 "$@"
    else "$@"; fi
}

bin=$(mktemp "${TMPDIR:-/tmp}/goose-io-faults.XXXXXX")
trap 'rm -f "$bin"' EXIT
# built once: the loops use threads, which `goose run` does not support
goose build tests/conformance/memory_conformance.goose -o "$bin" || exit 2

bad=0
tested=0
unfaulted=()
while IFS=$'\t' read -r check part req scenarios fault group; do
    case "$check" in ''|'#'*) continue ;; esac
    want "$check" || continue
    if [ "$fault" = "-" ]; then unfaulted+=("$check"); continue; fi
    # the fault column holds one fault, or several separated by commas: the check must fail under each of them
    for one in ${fault//,/ }; do
        out=$(GOOSE_IO_FAULT="$one" limited "$bin" "$part" "$group" 2>&1)
        code=$?
        tested=$((tested + 1))
        if grep -q "^FAIL $check " <<<"$out"; then
            others=$(grep -c "^FAIL " <<<"$out")
            echo "ok    $check fails with $one ($others failing in part $part)"
        else
            echo "BAD   $check passes with its fault $one (exit $code)"
            sed 's/^/        /' <<<"$out" | tail -n 5
            bad=$((bad + 1))
        fi
    done
done < tests/conformance/checks.tsv

if [ ${#unfaulted[@]} -gt 0 ]; then echo "no fault possible, see docs/event-loops.md: ${unfaulted[*]}"; fi
echo "$tested faults tried, $bad checks that did not fail"

# an unknown fault name must not silently pass: the Fault enum in memory.goose has to have every name used
for f in $(grep -v '^#' tests/conformance/checks.tsv | cut -f5 | grep -v '^-$' | tr ',' '\n'); do
    grep -qw "$f" <(sed -n '/^enum Fault {/,/^}/p' memory.goose) || { echo "BAD   fault $f is not in memory.goose"; bad=$((bad + 1)); }
done
[ $bad -eq 0 ]
