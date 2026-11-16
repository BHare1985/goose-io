#!/usr/bin/env bash
# Runs the conformance suite against the in-memory event loop, one group at a time and one process for each part of a
# group: the core (parts 0 to 5, one for each scenario of `stop`) and then each group of extras (part 0).
# Usage: tests/conformance/run.sh [--wrapped | --core-only] [--group G] [--repeat N]
# With --wrapped the parts run on the wrapper of tests/support/wrapper.goose, over the in-memory event loop.
# With --core-only the core runs on the loop of tests/support/core_only.goose, which supplies nothing else.
# With --group G only that group runs (core, half-close, sizing, abort, inspection or batching).
# A part that fails in any repetition fails the run, and the output of every repetition of a part must be
# identical to the first (the in-memory event loop is deterministic), so an intermittent failure is never hidden.
set -u
cd "$(dirname "$0")/../.."

repeat=1
prog=memory_conformance
only=
while [ $# -gt 0 ]; do
    case "$1" in
        --wrapped) prog=wrapped_conformance ;;
        --core-only) prog=core_only_conformance; only=core ;;
        --group) shift; only="${1:?--group needs a name}" ;;
        --repeat) shift; repeat="${1:?--repeat needs a number}" ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done

tsv=tests/conformance/checks.tsv
# the groups and parts are the ones checks.tsv names (part is the second column, group the sixth)
if [ -n "$only" ]; then groups=("$only"); else groups=($(grep -v '^#' "$tsv" | cut -f6 | sort -u)); fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goose-io-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failed=0
total=0
for g in "${groups[@]}"; do
    parts=($(grep -v '^#' "$tsv" | awk -F'\t' -v g="$g" '$6 == g {print $2}' | sort -un))
    [ ${#parts[@]} -gt 0 ] || { echo "no checks in group $g"; exit 2; }
    for ((i = 1; i <= repeat; i++)); do
        for p in "${parts[@]}"; do
            out="$tmp/out.$g.$p.$i"
            goose run "tests/conformance/$prog.goose" -- "$p" "$g" > "$out" 2>&1
            code=$?
            if [ $code -ne 0 ]; then
                echo "FAIL  $g part $p, repetition $i (exit $code)"
                sed 's/^/      /' "$out"
                failed=$((failed + 1))
            elif [ $i -gt 1 ] && ! cmp -s "$out" "$tmp/out.$g.$p.1"; then
                echo "FAIL  $g part $p, repetition $i: output differs from the first repetition"
                diff "$tmp/out.$g.$p.1" "$out" | sed 's/^/      /'
                failed=$((failed + 1))
            elif [ $i -eq 1 ]; then
                echo "ok    $g part $p: $(tail -n 1 "$out")"
            fi
        done
    done
    total=$((total + ${#parts[@]}))
done
echo "$total parts in ${#groups[@]} groups x $repeat repetitions, $failed failed"
[ $failed -eq 0 ]
