#!/usr/bin/env bash
# Checks that code quoted in the documents is the code in the repository.
# A line `<!-- source: path -->` in a Markdown file says that the fenced block that follows it is
# the whole of that file. A line `<!-- excerpt: path#name -->` says that the fenced block that follows it is the
# lines of that file between `// doc:begin name` and `// doc:end name` (the marker lines themselves left out).
# This script fails if any such block differs from its source.
set -u
cd "$(dirname "$0")/../.."

failed=0
checked=0
tmp=$(mktemp "${TMPDIR:-/tmp}/goose-io-docs.XXXXXX")
trap 'rm -f "$tmp"' EXIT

for doc in README.md docs/*.md; do
    [ -f "$doc" ] || continue
    while IFS= read -r path; do
        checked=$((checked + 1))
        # the lines between the first fence after the marker and the fence that closes it
        awk -v want="<!-- source: $path -->" '
            $0 == want { armed = 1; next }
            armed && /^```/ { if (inside) exit; inside = 1; next }
            inside { print }
        ' "$doc" > "$tmp"
        if [ ! -f "$path" ]; then
            echo "FAIL  $doc quotes $path, which does not exist"
            failed=$((failed + 1))
        elif ! diff -q "$tmp" "$path" > /dev/null; then
            echo "FAIL  $doc: the block marked '$path' differs from the file"
            diff "$tmp" "$path" | head -n 10 | sed 's/^/      /'
            failed=$((failed + 1))
        else
            echo "ok    $doc quotes $path"
        fi
    done < <(sed -n 's|^<!-- source: \(.*\) -->$|\1|p' "$doc")
done

while IFS= read -r ref; do
    path="${ref%%#*}"
    name="${ref##*#}"
    checked=$((checked + 1))
    doc_file=""
    for doc in README.md docs/*.md; do
        [ -f "$doc" ] && grep -qF "<!-- excerpt: $ref -->" "$doc" && doc_file="$doc" && break
    done
    awk -v want="<!-- excerpt: $ref -->" '
        $0 == want { armed = 1; next }
        armed && /^```/ { if (inside) exit; inside = 1; next }
        inside { print }
    ' "$doc_file" > "$tmp"
    if [ ! -f "$path" ]; then
        echo "FAIL  $doc_file excerpts $path, which does not exist"
        failed=$((failed + 1))
    else
        awk -v b="// doc:begin $name" -v e="// doc:end $name" '$0 == e { on = 0 } on { print } $0 == b { on = 1 }' "$path" > "$tmp.src"
        if [ ! -s "$tmp.src" ]; then
            echo "FAIL  $doc_file: no // doc:begin $name in $path"
            failed=$((failed + 1))
        elif ! diff -q "$tmp" "$tmp.src" > /dev/null; then
            echo "FAIL  $doc_file: the excerpt $ref differs from the file"
            diff "$tmp" "$tmp.src" | head -n 10 | sed 's/^/      /'
            failed=$((failed + 1))
        else
            echo "ok    $doc_file excerpts $ref"
        fi
    fi
done < <(cat README.md docs/*.md 2>/dev/null | sed -n 's|^<!-- excerpt: \(.*\) -->$|\1|p')

echo "$checked quoted files, $failed failed"
[ $failed -eq 0 ]
