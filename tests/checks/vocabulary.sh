#!/usr/bin/env bash
# The words of the contract are "event loop" (what supplies the operations and events), "library" (what handles
# events and calls operations) and "application" (what runs the loop). The old word "provider" must not
# come back (and "host" no longer is checked: it is also a URL authority and libpq's host setting): this fails on it, in the documents, the code, the scripts and the specification, and lists the
# files with the number of lines for each, most first, which is the order to sweep them in.
# Allowed: docs/event-loops/declarations.md (names the old words, for loops that still use them) and tests/conformance/table_check.sh, which names the old words to translate them; the capability id `provider-conformance` (OpenSpec does not rename a capability: design D1), and the records of changes under
# openspec/changes/ and docs/history.md, which say what was true when they were written.
# The whole word "group" (and "groups") is checked too, since `rename-groups-to-capabilities`: what the contract calls an optional part is a
# capability. Allowed, line by line: the CI concurrency key `group:` in .github/workflows/ci.yml, a benchmark's "group of arms"
# in bench/link_map_bench.goose, a regular expression's `.group(` call in bench/*.py, and the names of the two changes
# `add-proxy-groups` and `rename-groups-to-capabilities`. openspec/specs/ is excluded until that change is archived, because the
# archive restates it (remove that exclusion then).
# Also checked: no file or directory name contains the old words (the capability directory excepted).
# Usage: tests/checks/vocabulary.sh
set -u
cd "$(dirname "$0")/../.."

words="(^|[^A-Za-z0-9_])(provider|groups?)(s|'s)?($|[^A-Za-z0-9_])"
allowed="provider-conformance|add-proxy-groups|rename-groups-to-capabilities|[0-9]+:[[:space:]]*group: ci-|group of arms|\\.group\\("

files=()
while IFS= read -r f; do
    case "$f" in
        openspec/changes/*|openspec/specs/*|docs/history.md|docs/event-loops/declarations.md|tests/checks/vocabulary.sh|tests/conformance/table_check.sh|skills-lock.json) continue ;;
    esac
    [ -f "$f" ] && files+=("$f")
done < <(git ls-files --cached --others --exclude-standard)

report=$(mktemp "${TMPDIR:-/tmp}/goose-io-vocabulary.XXXXXX")
trap 'rm -f "$report"' EXIT
found=0
for f in "${files[@]}"; do
    hits=$(grep -inE "$words" "$f" 2>/dev/null | grep -viE "$allowed" | wc -l)
    if [ "${hits:-0}" -gt 0 ]; then
        printf '%5d  %s\n' "$hits" "$f" >> "$report"
        found=$((found + hits))
    fi
done

names=$(printf '%s\n' "${files[@]}" | grep -iE "provider" | grep -v '^openspec/specs/provider-conformance/' || true)

if [ -s "$report" ] || [ -n "$names" ]; then
    echo "old words found: $found lines (provider, group), in the files below, most first"
    sort -rn "$report" | sed 's/^/  /'
    if [ -n "$names" ]; then echo "file names that contain an old word:"; sed 's/^/  /' <<<"$names"; fi
    if [ "${VOCABULARY_LINES:-}" = 1 ]; then
        for f in "${files[@]}"; do grep -inE "$words" "$f" 2>/dev/null | grep -viE "$allowed" | sed "s|^|$f:|"; done
    fi
    exit 1
fi
echo "vocabulary: ${#files[@]} files inspected, 0 problems"
