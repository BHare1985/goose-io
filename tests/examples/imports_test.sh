#!/usr/bin/env bash
# Inspection: the example libraries are written only against the contract.
#  - a source under examples/lineserver or examples/lineclient imports std and goose_io (and files of its own
#    library) and nothing else, so it names no event loop;
#  - neither library's source names the other.
# Usage: tests/examples/imports_test.sh
set -u
cd "$(dirname "$0")/../.."

bad=0
checked=0
for lib in lineserver lineclient; do
    [ -d "examples/$lib" ] || continue
    other=lineclient; [ "$lib" = lineclient ] && other=lineserver
    for f in examples/$lib/*.goose; do
        [ -f "$f" ] || continue
        checked=$((checked + 1))
        while IFS= read -r name; do
            case "$name" in
                std|goose_io|goose_io.deadlines|deadlines) ;;
                *) if [ ! -f "examples/$lib/$name.goose" ]; then echo "BAD   $f imports $name"; bad=$((bad + 1)); fi ;;
            esac
        done < <(grep -E '^import ' "$f" | sed -E 's/^import ([A-Za-z0-9_.]+).*/\1/')
        if grep -qiE "$other|goose_io_memory|goose_io.memory|core_only|wrapper" "$f"; then echo "BAD   $f names $other or an event loop"; bad=$((bad + 1)); fi
    done
done
echo "$checked library files inspected, $bad problems"
[ $bad -eq 0 ] && [ $checked -gt 0 ]
