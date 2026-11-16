#!/usr/bin/env bash
# Runs every part of the conformance suite against the in-memory provider, one process per part.
# Usage: tests/conformance/run.sh [--wrapped] [--group G] [--repeat N]
# With --group G only the checks of that group run (core or batching for now; all of them by default), each part
# of the group in its own process.
# With --wrapped the parts run on the wrapper of tests/support/wrapper.goose, over the in-memory provider.
# A part that fails in any repetition fails the run, and the output of every repetition of a part must be
# identical to the first (the in-memory provider is deterministic), so an intermittent failure is never hidden.
set -u
cd "$(dirname "$0")/../.."

repeat=1
prog=memory_conformance
group=
while [ $# -gt 0 ]; do
    case "$1" in
        --wrapped) prog=wrapped_conformance ;;
        --group) shift; group="${1:?--group needs a name}" ;;
        --repeat) shift; repeat="${1:?--repeat needs a number}" ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done
# the parts are the ones checks.tsv names (a part number is the second column)
if [ -n "$group" ]; then
    parts=($(grep -v '^#' tests/conformance/checks.tsv | awk -F'\t' -v g="$group" '$6 == g {print $2}' | sort -un))
else
    parts=($(grep -v '^#' tests/conformance/checks.tsv | cut -f2 | sort -un))
fi
[ ${#parts[@]} -gt 0 ] || { echo "no checks in group ${group:-all}"; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goose-io-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failed=0
for ((i = 1; i <= repeat; i++)); do
    for p in "${parts[@]}"; do
        out="$tmp/out.$p.$i"
        goose run "tests/conformance/$prog.goose" -- "$p" $group > "$out" 2>&1
        code=$?
        if [ $code -ne 0 ]; then
            echo "FAIL  part $p, repetition $i (exit $code)"
            sed 's/^/      /' "$out"
            failed=$((failed + 1))
        elif [ $i -gt 1 ] && ! cmp -s "$out" "$tmp/out.$p.1"; then
            echo "FAIL  part $p, repetition $i: output differs from the first repetition"
            diff "$tmp/out.$p.1" "$out" | sed 's/^/      /'
            failed=$((failed + 1))
        elif [ $i -eq 1 ]; then
            echo "ok    part $p: $(tail -n 1 "$out")"
        fi
    done
done
echo "${#parts[@]} parts x $repeat repetitions, $failed failed"
[ $failed -eq 0 ]
