#!/usr/bin/env bash
# Every capability the contract declares has a page of the fixed shape (docs/capabilities/<name>.md), and the index lists it.
# The capabilities are the `fn has_<name><` lines of goose_io.goose, and a capability's operations and events are on the
# comment line above its `fn require_<name><`: `name(` is an operation, `event X` is an event. A page needs, in this order,
# the sections below; "What it is" names every operation and event; "Examples" has a `source:` or `excerpt:` block.
# Usage: tests/checks/capability_pages.sh [root]   (root defaults to the repository; fixtures pass their own)
set -u
root="${1:-$(dirname "$0")/../..}"
src="$root/goose_io.goose"
pages="$root/docs/capabilities"

SECTIONS=("What it is" "When to use it" "How it is commonly used" "Examples" "Required or optional" "Supplied by" "See also")
bad=0
n=0
problem() { echo "BAD   $1"; bad=$((bad + 1)); }

caps=$(sed -n 's/^fn has_\([a-z_0-9]*\)<.*/\1/p' "$src")
[ -n "$caps" ] || { echo "BAD   no capability found in $src"; exit 1; }

for c in $caps; do
    n=$((n + 1))
    name="${c//_/-}"
    page="$pages/$name.md"
    if [ ! -f "$page" ]; then
        problem "capability $name has no page: docs/capabilities/$name.md"
        continue
    fi
    # the sections that are there, in the order they appear
    found=$(grep '^## ' "$page" | sed 's/^## //')
    last=0
    for i in "${!SECTIONS[@]}"; do
        s="${SECTIONS[$i]}"
        at=$(echo "$found" | grep -nxF "$s" | head -n 1 | cut -d: -f1)
        if [ -z "$at" ]; then
            problem "docs/capabilities/$name.md has no section \"$s\""
        elif [ "$at" -lt "$last" ]; then
            problem "docs/capabilities/$name.md has the section \"$s\" out of order"
        else
            last=$at
        fi
    done
    # operations and events from the comment above require_<c>
    comment=$(awk -v f="fn require_$c<" 'index($0, f) == 1 { print prev } { prev = $0 }' "$src")
    items=$( { echo "$comment" | grep -oE '[a-z_0-9]+\(' | tr -d '('; echo "$comment" | grep -oE 'events? [A-Z][A-Za-z]+' | sed 's/^events\? //'; } | sort -u)
    what=$(awk '/^## /{on = ($0 == "## What it is")} on' "$page")
    for item in $items; do
        echo "$what" | grep -qw -- "$item" || problem "docs/capabilities/$name.md: \"What it is\" does not name $item"
    done
    examples=$(awk '/^## /{on = ($0 == "## Examples")} on' "$page")
    echo "$examples" | grep -qE '^<!-- (source|excerpt): ' || problem "docs/capabilities/$name.md: \"Examples\" has no source: or excerpt: block"
    grep -q "($name.md)" "$pages/README.md" 2>/dev/null || problem "docs/capabilities/README.md does not list $name.md"
done

for page in "$pages"/*.md; do
    [ -f "$page" ] || continue
    base=$(basename "$page" .md)
    [ "$base" = README ] && continue
    echo "$caps" | tr _ - | grep -qx "$base" || problem "docs/capabilities/$base.md is a page for a capability the contract does not declare"
done

echo "capability pages: $n capabilities inspected, $bad problems"
[ $bad -eq 0 ]
