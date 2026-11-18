#!/usr/bin/env bash
# The contract package is pure Goose: no C source or header, no build sidecar and no `extern` anywhere in it,
# except anywhere.
# Usage: tests/checks/purity.sh   (run by tests/run_tests.sh)
set -u
cd "$(dirname "$0")/../.."

# every file of the package, without tooling, planning and version-control directories (no git needed: the check
# also runs on a plain copy of the tree)
files=$(find . -type f -not -path './.git/*' -not -path './.agents/*' -not -path './.claude/*' -not -path './openspec/*' -not -path './.implementations/*' -not -name 'skills-lock.json' | sed 's|^\./||')
bad=0

native=$(echo "$files" | grep -E '\.(c|h|cc|cpp|hpp|build)$' || true)
if [ -n "$native" ]; then echo "BAD   native or build files in the package:"; echo "$native" | sed 's/^/        /'; bad=$((bad + 1)); fi

# a Goose source that declares or calls an external function
externs=$(echo "$files" | grep -E '\.goose$' | xargs grep -nE '^[[:space:]]*(export[[:space:]]+)?extern[[:space:]]' 2>/dev/null || true)
if [ -n "$externs" ]; then echo "BAD   extern in Goose sources:"; echo "$externs" | sed 's/^/        /'; bad=$((bad + 1)); fi

n=$(echo "$files" | grep -cE '\.goose$')
echo "purity: $n Goose files inspected, $bad problems"
[ $n -gt 0 ] && [ $bad -eq 0 ]
