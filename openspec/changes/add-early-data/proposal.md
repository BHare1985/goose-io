## Why

A client that sends a request as soon as its connection opens waits one round trip for the handshake before the request leaves. TCP Fast Open (`MSG_FASTOPEN`, `connectx` on macOS) lets the first bytes ride on the SYN to a server that has seen the client before, saving that round trip. A server must opt in to accept such bytes. The cost is a known one: bytes on a SYN may reach the server application more than once, so only a request that is safe to repeat may be sent this way. The research behind this proposal ("EarlyData") also mentioned TLS and QUIC 0-RTT. QUIC is datagrams, out of scope. TLS 0-RTT is a TLS library's business above the contract, and it can use this capability for its first flight.

## What Changes

- Add the early-data capability: `dial_with_data(address, connect_ms, first)` dials as `dial` does, and the link's first bytes are `first`, which the loop may send with the connection's opening. `max_early_data()` bounds `first`.
- On the server side, `accept_early_data(listener, on)` lets a listener accept bytes that arrive with a connection's opening; they are delivered as the link's first `Data` right after `Opened`.
- State the replay rule: bytes sent early may reach the peer's application more than once. The capability page says to send only requests that are safe to repeat.
- Declare the capability as every capability is declared (`supplies_early_data` and `goose_io::has_early_data`, from `rename-groups-to-capabilities`), with a compile-time check `require_early_data` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (early bytes carried with the opening), and a named fault for every check.
- Add `docs/capabilities/early-data.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/early_get.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: TLS and QUIC 0-RTT (a TLS library's or datagram transport's), reporting whether the bytes actually rode on the opening, and a cookie or ticket cache API (the system keeps it).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the early data capability: the operations `dial_with_data(address, connect_ms, first) -> Link`, `max_early_data() -> i64` and `accept_early_data(listener, on) -> bool`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the early data suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/early-data.md` exists and covers what early data saves, the replay rule and which requests are safe to send early, and the server opt-in.

## Impact

- **goose-io code:** `goose_io.goose` (the three operations, the declaration and query, `require_early_data`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A client library may dial with data when the loop supplies it and send at `Opened` otherwise.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`TCP_FASTOPEN`/`MSG_FASTOPEN` and `TCP_FASTOPEN_CONNECT` on Linux, `connectx` with `CONNECT_DATA_IDEMPOTENT` on macOS, a send at open elsewhere).
- **Documents:** `docs/capabilities/early-data.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
