#!/usr/bin/env bash
# Runs every *_test.goose and *_mustfail.goose under tests/ with `goose run`.
# A *_test.goose file passes when it exits 0. A *_mustfail.goose file passes when it exits
# non-zero and its output contains the text after "// expect: " on its first line.
# Prints one line per file and exits non-zero if any file fails.
# Usage: tests/run_tests.sh [directory-or-file ...]   (default: tests/)
set -u
cd "$(dirname "$0")/.."

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then targets=(tests); fi

files=()
for t in "${targets[@]}"; do
    if [ -d "$t" ]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "$t" \( -name '*_test.goose' -o -name '*_mustfail.goose' \) | sort)
    else
        files+=("$t")
    fi
done

if [ ${#files[@]} -eq 0 ]; then
    echo "no *_test.goose or *_mustfail.goose files found under: ${targets[*]}"
    exit 1
fi

failed=0
for f in "${files[@]}"; do
    out=$(goose run "$f" 2>&1)
    code=$?
    if [[ "$f" == *_mustfail.goose ]]; then
        want=$(head -n 1 "$f" | sed -n 's|^// expect: ||p')
        if [ $code -ne 0 ] && [ -n "$want" ] && grep -qF -- "$want" <<<"$out"; then
            echo "ok    $f (failed as it must)"
        else
            echo "FAIL  $f (exit $code; must exit non-zero and print: $want)"
            echo "$out" | sed 's/^/      /'
            failed=$((failed + 1))
        fi
    elif [ $code -eq 0 ]; then
        echo "ok    $f"
    else
        echo "FAIL  $f (exit $code)"
        echo "$out" | sed 's/^/      /'
        failed=$((failed + 1))
    fi
done

# the package stays pure Goose (docs/providers.md, "Which check proves which scenario")
if [ -z "${SKIP_PURITY:-}" ] && [ ${#targets[@]} -eq 1 ] && [ "${targets[0]}" = "tests" ]; then
    tests/checks/purity.sh || failed=$((failed + 1))
fi

echo "${#files[@]} files, $failed failed"
[ $failed -eq 0 ]
