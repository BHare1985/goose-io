#!/usr/bin/env bash
# The words of the contract are "event loop" (what supplies the operations and events), "library" (what handles
# events and calls operations) and "application" (what runs the loop). The old words "provider" and "host" must not
# come back: this fails on either, in the documents, the code, the scripts and the specification, and lists the
# files with the number of lines for each, most first, which is the order to sweep them in.
# Allowed: tests/conformance/table_check.sh, which names the old words to translate them; the capability id `provider-conformance` (OpenSpec does not rename a capability: design D1), the word
# "host" in "localhost" or in the host-name sense of an address, and the records of changes under
# openspec/changes/ and docs/history.md, which say what was true when they were written.
# Also checked: no file or directory name contains the old words (the capability directory excepted).
# Usage: tests/checks/vocabulary.sh
set -u
cd "$(dirname "$0")/../.."

words="\\b(provider|host)(s|'s)?\\b"
allowed="provider-conformance|localhost|host name|host-name|hostname|host part|host or"

files=()
while IFS= read -r f; do
    case "$f" in
        openspec/changes/*|docs/history.md|tests/checks/vocabulary.sh|tests/conformance/table_check.sh|skills-lock.json) continue ;;
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

names=$(printf '%s\n' "${files[@]}" | grep -iE "provider|host" | grep -v '^openspec/specs/provider-conformance/' || true)

if [ -s "$report" ] || [ -n "$names" ]; then
    echo "old words found: $found lines (provider, host), in the files below, most first"
    sort -rn "$report" | sed 's/^/  /'
    if [ -n "$names" ]; then echo "file names that contain an old word:"; sed 's/^/  /' <<<"$names"; fi
    if [ "${VOCABULARY_LINES:-}" = 1 ]; then
        for f in "${files[@]}"; do grep -inE "$words" "$f" 2>/dev/null | grep -viE "$allowed" | sed "s|^|$f:|"; done
    fi
    exit 1
fi
echo "vocabulary: ${#files[@]} files inspected, 0 problems"
