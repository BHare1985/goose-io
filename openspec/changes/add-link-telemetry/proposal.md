## Why

A proxy that picks the least loaded backend, a server that sheds load when its clients' round-trip times grow, an adaptive bitrate sender, and every access log that wants more than bytes and duration need to read the transport's own state: smoothed round-trip time, retransmits, bytes in flight, bytes not yet read. Linux has `TCP_INFO` and `TCP_CM_INQ`, macOS `TCP_CONNECTION_INFO`, FreeBSD `TCP_INFO`. The contract has `peer_address` and `relayed_bytes` and nothing more. The research behind this proposal joined this with congestion control and pacing. Pacing is a hint in `add-transport-hints`, so this capability only reads.

## What Changes

- Add the link-telemetry capability: `link_stats(link)` returns a `LinkStats` with the bytes the loop accepted, handed to the transport, and received; bytes in flight; bytes the transport holds unread; smoothed round-trip time and its variation in microseconds; retransmits; and the delivery rate in bytes per second.
- State what each field means and that a field the loop cannot measure is -1, so a library never mistakes unknown for zero.
- Declare the capability as every capability is declared (`supplies_link_telemetry` and `goose_io::has_link_telemetry`, from `rename-groups-to-capabilities`), with a compile-time check `require_link_telemetry` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (exact counters, scripted round-trip time), and a named fault for every check.
- Add `docs/capabilities/link-telemetry.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/least_rtt.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: setting any transport parameter (`add-transport-hints`), congestion algorithm choice, ECN, and statistics of the loop as a whole.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the link telemetry capability: the operation `link_stats(link) -> LinkStats` and the type `LinkStats`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the link telemetry suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/link-telemetry.md` exists and covers every field and when it is unknown, how often reading it is cheap, and what decisions it supports.

## Impact

- **goose-io code:** `goose_io.goose` (the struct `LinkStats` and `link_stats`, the declaration and query, `require_link_telemetry`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`TCP_INFO` and `TCP_CM_INQ` on Linux, `TCP_CONNECTION_INFO` on macOS, `TCP_INFO` on FreeBSD; the loop's own counters everywhere).
- **Documents:** `docs/capabilities/link-telemetry.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
