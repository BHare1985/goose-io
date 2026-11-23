#!/usr/bin/env bash
# Runs the conformance suite against the in-memory event loop, one capability at a time and one process for each part of a
# capability: the core (parts 0 to 5, one for each scenario of `stop`) and then each capability (part 0).
# Usage: tests/conformance/run.sh [--wrapped | --core-only] [--capability G] [--repeat N]
# With --wrapped the parts run on the wrapper of tests/support/wrapper.goose, over the in-memory event loop.
# With --core-only the core runs on the loop of tests/support/core_only.goose, which supplies nothing else.
# With --capability G only that capability runs (core, half-close, sizing, abort, inspection or batching).
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
        --capability) shift; only="${1:?--capability needs a name}" ;;
        --repeat) shift; repeat="${1:?--repeat needs a number}" ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done

tsv=tests/conformance/checks.tsv
# the capabilities and parts are the ones checks.tsv names (part is the second column, capability the sixth)
if [ -n "$only" ]; then capabilities=("$only"); else capabilities=($(grep -v '^#' "$tsv" | cut -f6 | sort -u)); fi
# the wrapper supplies the core and the first six capabilities; the proxy capabilities run on the in-memory loop only
if [ "$prog" = wrapped_conformance ] && [ -z "$only" ]; then
    capabilities=($(printf '%s\n' "${capabilities[@]}" | grep -vxE 'relay|peek|revoke|wake|limits'))
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goose-io-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# built once: the loops use threads, which `goose run` does not support
bin="$tmp/$prog"
goose build "tests/conformance/$prog.goose" -o "$bin" > "$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 2; }

failed=0
total=0
for g in "${capabilities[@]}"; do
    parts=($(grep -v '^#' "$tsv" | awk -F'\t' -v g="$g" '$6 == g {print $2}' | sort -un))
    [ ${#parts[@]} -gt 0 ] || { echo "no checks in capability $g"; exit 2; }
    for ((i = 1; i <= repeat; i++)); do
        for p in "${parts[@]}"; do
            out="$tmp/out.$g.$p.$i"
            "$bin" "$p" "$g" > "$out" 2>&1
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
echo "$total parts in ${#capabilities[@]} capabilities x $repeat repetitions, $failed failed"
[ $failed -eq 0 ]
