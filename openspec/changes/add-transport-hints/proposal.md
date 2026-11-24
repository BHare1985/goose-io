## Why

`docs/contract.md` section 11 makes socket options the event loop's configuration, which the application sets once for every link. That covers a loop whose links all want the same treatment. It does not cover a library whose links differ: a proxy that keeps Nagle off on its client side and sends bulk on its backend side; an RPC library that wants small replies out at once while a file transfer on the same loop wants full segments; a server that sends a header and body in several `send`s per pass and wants them coalesced into full packets; a long-lived idle link that wants keepalive probes; a streaming sender that wants `Writable` only when the kernel queue is nearly empty, so its latest data is not stuck behind stale data; a server that paces a slow client. Each has a socket option behind it (`TCP_NODELAY`, `TCP_CORK`/`MSG_MORE`, `SO_KEEPALIVE` with `TCP_KEEPIDLE`, `TCP_NOTSENT_LOWAT`, `SO_MAX_PACING_RATE`). The research notes this proposal draws on called this "SocketOpts" or "TransportHints" and also folded congestion pacing into a separate capability. Here pacing is one more hint, because, like the others, it changes timing and never bytes.

## What Changes

- Add the transport-hints capability: `set_hint(link, hint, value) -> bool` with `Hint` one of `NoDelay` (value 1 or 0: hand small sends to the transport at once), `Coalesce` (1 or 0: hold small sends to fill segments, handed over no later than the end of the pass), `KeepAlive` (seconds of idleness before probes, 0 off), `SendLowWater` (bytes: deliver `Writable` only when fewer than this many accepted bytes wait), `PacingRate` (bytes per second, 0 unpaced).
- State the rule that makes hints safe to ignore: a hint changes when bytes reach the transport and when `Writable` is delivered, never which bytes are delivered, in what order, or the result of any operation. `set_hint` returns whether the loop applied it.
- Declare the capability as every capability is declared (`supplies_transport_hints` and `goose_io::has_transport_hints`, from `rename-groups-to-capabilities`), with a compile-time check `require_transport_hints` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (hints recorded, coalescing to the end of a pass, low water, pacing on the virtual clock), and a named fault for every check.
- Add `docs/capabilities/transport-hints.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/rpc_and_bulk.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: per-listener options (backlog, `SO_REUSEPORT`, which `add-shared-listen` proposes; deferred accept, which `add-deferred-accept` proposes), buffer sizes, which stay loop configuration, congestion-control algorithm choice, ECN, and reading the transport's state, which `add-link-telemetry` proposes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the transport hints capability: the operation `set_hint(link, hint, value) -> bool` and the type `Hint` (`NoDelay`, `Coalesce`, `KeepAlive`, `SendLowWater`, `PacingRate`), and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the transport hints suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/transport-hints.md` exists and covers each hint, what it changes and what it never changes, and when a library would set one per link instead of relying on the loop's configuration.

## Impact

- **goose-io code:** `goose_io.goose` (the enum `Hint` and `set_hint`, the declaration and query, `require_transport_hints`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A library that wants a hint uses it optionally: on a loop without it, it sends as before.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`TCP_NODELAY`, `TCP_CORK`/`MSG_MORE`, `SO_KEEPALIVE`, `TCP_NOTSENT_LOWAT`, `SO_MAX_PACING_RATE`; ignored by loops without them).
- **Documents:** `docs/capabilities/transport-hints.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
