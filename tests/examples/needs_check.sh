#!/usr/bin/env bash
# Inspection: every example library says in its header which groups of the contract it needs ("// Needs: core and
# half-close ..."), and the header names every group whose operations the library calls, directly or through the
# libraries it imports. A library that calls an operation of a group its header does not name fails here.
# Usage: tests/examples/needs_check.sh [file ...]   (default: every library file under examples/)
set -u
cd "$(dirname "$0")/../.."

# the operations of each group (docs/contract.md), as the calls `io.<operation>(` (a function and not an array, which
# the bash of macOS lacks)
ops_of() {
    case "$1" in
        half-close) echo 'set_keep_open_on_eof|shutdown_write' ;;
        sizing) echo 'send_room|send2' ;;
        abort) echo 'reset' ;;
        inspection) echo 'peer_address|stop_listening|user' ;;
    esac
}
groups=(half-close sizing abort inspection)

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    files=(examples/gateway.goose examples/dispatch.goose)
    for f in examples/*/*.goose; do files+=("$f"); done
fi

# the groups a file's header names: the words of the first line of its "Needs:" sentence, up to its first "(" or "."
named() {
    sed -n 's|^// Needs: \([^(.]*\).*|\1|p' "$1" | head -n 1
}

# the groups a file needs: those of the operations it calls and of the library files it imports
needed() {
    local f="$1" g
    for g in "${groups[@]}"; do
        if grep -vE '^[[:space:]]*//' "$f" | grep -qE "\.($(ops_of "$g"))\("; then echo "$g"; fi
    done
    while IFS= read -r name; do
        local lib="${name//./\/}.goose"
        [ -f "$lib" ] && [ "$lib" != "$f" ] && needed "$lib"
    done < <(grep -E '^import examples\.' "$f" | sed -E 's/^import ([A-Za-z0-9_.]+).*/\1/')
}

bad=0
for f in "${files[@]}"; do
    header=$(named "$f")
    if [ -z "$header" ]; then echo "BAD   $f has no \"// Needs:\" line in its header"; bad=$((bad + 1)); continue; fi
    before=$bad
    for g in $(needed "$f" | sort -u); do
        if ! grep -q -- "$g" <<<"$header"; then
            echo "BAD   $f calls the $g group and its header names only: $header"
            bad=$((bad + 1))
        fi
    done
    [ $bad -eq $before ] && echo "ok    $f needs: $header"
done
echo "${#files[@]} libraries inspected, $bad problems"
[ $bad -eq 0 ]
