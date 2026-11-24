#!/usr/bin/env bash
# Proves that tests/checks/capability_pages.sh fails when it should: each directory under
# tests/checks/fixtures/capability_pages/ is a small repository root; `good` must pass, every other must fail
# with the message in the table below.
set -u
cd "$(dirname "$0")/../.."
F=tests/checks/fixtures/capability_pages
failed=0
expect() { # case message
    out=$(bash tests/checks/capability_pages.sh "$F/$1" 2>&1); rc=$?
    if [ "$1" = good ]; then
        [ $rc -eq 0 ] && echo "ok    $1 passes" || { echo "FAIL  good fixture fails: $out"; failed=$((failed + 1)); }
    elif [ $rc -ne 0 ] && echo "$out" | grep -qF -- "$2"; then
        echo "ok    $1 fails: $2"
    else
        echo "FAIL  $1 should fail with: $2 (got rc=$rc: $out)"; failed=$((failed + 1))
    fi
}
expect good ""
expect missing_page "capability batching has no page"
expect missing_section 'sizing.md has no section "When to use it"'
expect section_out_of_order 'sizing.md has the section'
expect operation_left_out '"What it is" does not name send2'
expect no_example 'sizing.md: "Examples" has no source: or excerpt: block'
expect not_in_index "README.md does not list batching.md"
echo "capability page fixtures: $failed failed"
[ $failed -eq 0 ]
