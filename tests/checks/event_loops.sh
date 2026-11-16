#!/usr/bin/env bash
# Checks the mapping documents of docs/event-loops/: every operation and event of the contract has a row, each
# document has its "Closing", "Connect failures" and "Known gaps" sections, and the documents that list
# unverified rows list them before the table. Usage: tests/checks/event_loops.sh
set -u
cd "$(dirname "$0")/../.."

items="listen listener_port stop_listening dial peer_address send send2 send_room max_send pause_reading set_keep_open_on_eof shutdown_write close reset set_user user now_ms tick_by serve stop draining Opened Data Writable PeerEof Closed Tick PassEnd"
bad=0
docs=0
for f in docs/event-loops/*.md; do
    [ -f "$f" ] || continue
    docs=$((docs + 1))
    for i in $items; do
        grep -q "^| \`$i\` |" "$f" || { echo "BAD   $f has no row for $i"; bad=$((bad + 1)); }
    done
    for h in "## Closing" "## Connect failures" "## Known gaps" "## Operations and events"; do
        grep -q "^$h" "$f" || { echo "BAD   $f has no section \"$h\""; bad=$((bad + 1)); }
    done
    # the unverified rows are listed before the table
    u=$(grep -n "^## Unverified rows" "$f" | head -n 1 | cut -d: -f1)
    t=$(grep -n "^## Operations and events" "$f" | head -n 1 | cut -d: -f1)
    if [ -z "$u" ] || [ -z "$t" ] || [ "$u" -gt "$t" ]; then echo "BAD   $f does not list its unverified rows before the table"; bad=$((bad + 1)); fi
    # a row marked as having no mapping must be answered by the Known gaps section naming it
    if grep -qi "no workable mapping" "$f" && ! grep -q "^## Known gaps" "$f"; then echo "BAD   $f has a row without a mapping and no Known gaps"; bad=$((bad + 1)); fi
done
# five event loop documents in all: tcprouter-engine, usockets, io-uring, libuv, libevent
for n in tcprouter-engine usockets io-uring libuv libevent; do
    [ -f "docs/event-loops/$n.md" ] || { echo "BAD   docs/event-loops/$n.md is missing"; bad=$((bad + 1)); }
done
echo "$docs documents, $bad problems"
[ $bad -eq 0 ] && [ $docs -gt 0 ]
