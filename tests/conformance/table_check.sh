#!/usr/bin/env bash
# Checks that the specification, docs/event-loops.md, tests/conformance/checks.tsv and the suite agree:
#  - the table in docs/event-loops.md has one row for each scenario of specs/io-contract/spec.md (counted with grep -c)
#  - every check in checks.tsv is named in the table or in the document, and every check the suite defines is in checks.tsv
#  - every fault named in checks.tsv is one memory.goose knows
# The specification is the one of the change define-contract-v1, wherever it is: active, or archived under
# openspec/changes/archive/<date>-define-contract-v1. Usage: tests/conformance/table_check.sh [path to its specs/io-contract/spec.md]
set -u
cd "$(dirname "$0")/../.."

spec="${1:-}"
if [ -z "$spec" ]; then
    for c in openspec/changes/define-contract-v1/specs/io-contract/spec.md openspec/changes/archive/*-define-contract-v1/specs/io-contract/spec.md; do
        [ -f "$c" ] && spec="$c" && break
    done
fi
[ -f "$spec" ] || { echo "BAD   no specification of define-contract-v1 found (active or archived)"; exit 1; }
doc=docs/event-loops.md
tsv=tests/conformance/checks.tsv
bad=0

# the scenarios of define-contract-v1 are quoted in the table with the old words replaced by the new ones
# (simplify-contract, design D10): "a provider" is "an event loop", "provider-specific" is "loop-specific"
words() { sed -E 's/provider-specific/loop-specific/; s/^A provider/An event loop/; s/ a provider/ an event loop/g; s/providers/event loops/g; s/provider/event loop/g; s/Provider/Event loop/g'; }

want=$(grep -c "^#### Scenario" "$spec")
have=$(awk '/<!-- scenarios:begin -->/{on=1; next} /<!-- scenarios:end -->/{on=0} on && /^\| / && !/^\| Requirement/ && !/^\|---/' "$doc" | wc -l)
if [ "$want" -ne "$have" ]; then echo "BAD   the table has $have rows, the specification has $want scenarios"; bad=$((bad + 1)); else echo "ok    $have scenarios, $have rows"; fi

while IFS= read -r scenario; do
    grep -qF "| $scenario |" "$doc" || { echo "BAD   scenario not in the table: $scenario"; bad=$((bad + 1)); }
done < <(grep "^#### Scenario" "$spec" | sed 's/^#### Scenario: //' | words)

suite=$(grep -ho 'name: "[a-z0-9_]*"' conformance/*.goose | sed 's/name: "//; s/"//' | grep -v '^selftest_' | sort)
listed=$(grep -v '^#' "$tsv" | cut -f1 | sort)
if [ "$suite" != "$listed" ]; then
    echo "BAD   the checks in the suite and in checks.tsv differ:"
    diff <(echo "$suite") <(echo "$listed") | sed 's/^/        /'
    bad=$((bad + 1))
else
    echo "ok    $(wc -l <<<"$listed") checks in the suite and in checks.tsv"
fi

for c in $listed; do grep -q "\`$c\`" "$doc" || { echo "BAD   check not named in $doc: $c"; bad=$((bad + 1)); }; done
for f in $(grep -v '^#' "$tsv" | cut -f5 | grep -v '^-$' | tr ',' '\n'); do
    grep -q "\"$f\"" memory.goose || { echo "BAD   fault not in memory.goose: $f"; bad=$((bad + 1)); }
done
echo "$bad problems"
[ $bad -eq 0 ]
