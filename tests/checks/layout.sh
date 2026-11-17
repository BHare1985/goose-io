#!/usr/bin/env bash
# The repository layout in CONTRIBUTING.md is true: every path listed under "## Repository layout" exists, and every
# top-level entry of the repository (leaving out names that start with a dot and the tooling lock file) is listed.
# A listed line is "- `path`: what it is". Usage: tests/checks/layout.sh
set -u
cd "$(dirname "$0")/../.."

section=$(awk '/^## Repository layout/{on=1; next} /^## /{on=0} on' CONTRIBUTING.md)
listed=$(echo "$section" | sed -n 's/^- `\([^`]*\)`.*/\1/p')
bad=0
n=0
for p in $listed; do
    n=$((n + 1))
    [ -e "${p%/}" ] || { echo "BAD   CONTRIBUTING lists $p, which does not exist"; bad=$((bad + 1)); }
done
for e in $(ls -A | grep -v -e '^\.' -e '^skills-lock\.json$'); do
    first=$(echo "$listed" | sed 's|/.*||' | sort -u)
    echo "$first" | grep -qx "$e" || { echo "BAD   top-level $e is not listed in CONTRIBUTING.md"; bad=$((bad + 1)); }
done
echo "layout: $n paths listed, $bad problems"
[ $n -gt 0 ] && [ $bad -eq 0 ]
