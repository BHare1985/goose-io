#!/usr/bin/env bash
# Every check calls only the core and its own capability (design D5 of the change simplify-contract). The calls of each
# check are read from its function in conformance/*.goose and compared with its capability in checks.tsv: a check of the core
# calls no operation of a capability; a check of a capability calls the operations of that capability and no other. A check marked
# "pending" has not been assigned yet and is only counted.
# Usage: tests/conformance/capabilities_check.sh
set -u
cd "$(dirname "$0")/../.."

tsv=tests/conformance/checks.tsv
bad=0
checked=0
pending=0
while IFS=$'\t' read -r check part req scenarios fault capability; do
    case "$check" in ''|'#'*) continue ;; esac
    if [ "$capability" = "pending" ]; then pending=$((pending + 1)); continue; fi
    body=$(awk -v f="fn c_$check<Io>" 'index($0, f) == 1 { on = 1 } on { print } on && /^}/ { exit }' conformance/*.goose)
    if [ -z "$body" ]; then echo "BAD   $check: no function c_$check in conformance/"; bad=$((bad + 1)); continue; fi
    used=$(
        {
            echo "$body" | grep -oE 'io\.(shutdown_write|set_keep_open_on_eof|send_room|send2|reset|peer_address|stop_listening|user|relay|relayed_bytes|waker|wait_input|peek|discard_unsent|write_deadline|wake|set_limit)\(' | sed 's/^io\.//; s/($//'
            echo "$body" | grep -q 'fill_to_room(' && echo send_room
            echo "$body" | grep -qE "'E'|PeerEof" && echo PeerEof
        } | sort -u
    )
    for op in $used; do
        case "$op" in
            shutdown_write|set_keep_open_on_eof|PeerEof) g=half-close ;;
            send_room|send2) g=sizing ;;
            reset) g=abort ;;
            peer_address|stop_listening|user) g=inspection ;;
            relay|relayed_bytes) g=relay ;;
            wait_input|peek) g=peek ;;
            discard_unsent|write_deadline) g=revoke ;;
            wake|waker) g=wake ;;
            set_limit) g=limits ;;
        esac
        if [ "$g" != "$capability" ]; then
            echo "BAD   $check (capability $capability) calls $op, which belongs to the capability $g"
            bad=$((bad + 1))
        fi
    done
    checked=$((checked + 1))
done < "$tsv"
echo "capabilities: $checked checks inspected, $pending pending, $bad problems"
[ $bad -eq 0 ] && [ $checked -gt 0 ]
