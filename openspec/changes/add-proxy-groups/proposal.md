## Why

The contract moves bytes only as `Data` and `send`, so every byte of a stream passes through a library's memory. tcprouter, the first real proxy to move onto goose-io, needs five things that this cannot express and must lose none of them in the move: forwarding between two sockets without the bytes entering the library, looking at the first bytes of a connection (a TLS hello) without consuming them, writing nothing after a deadline, being told by another thread, and timing out a connection whose bytes the library never sees (idle, half-closed, or stuck on a peer that does not read). A kernel can do the first two without userspace (`splice`, `MSG_PEEK`); the contract has no operation that lets a loop do so. Optional groups are the contract's way to add a capability that only some loops supply, with a stated meaning, a suite and a build error naming the operation on a loop that lacks it. This is the first of two passes (the second, `add-stream-extras`, covers features other programs need); it holds everything tcprouter needs.

## What Changes

- Add five optional groups to the contract; the core and the six existing groups are unchanged:
  - **relay**: `relay(a, b)` joins two links so the loop moves the bytes between them in both directions, with backpressure and half-close carried through and no `Data` for either link; `relayed_bytes(link)`.
  - **peek**: `peek(link)` shows the bytes that have arrived and not yet been given as `Data`; `wait_input(link, n)` holds `Data` back until `n` bytes (or the peer's end) have arrived and the event `Input` says so; the bytes stay for `Data` afterwards.
  - **revoke**: `discard_unsent(link)` takes back bytes the loop has not yet handed to the transport; `write_deadline(link, at_ms)` makes the loop write nothing after a time, checked at the moment of each write.
  - **wake**: `waker()` and `wake(waker, value)`, callable from any thread, and the event `Woken` delivered on the loop's thread.
  - **limits**: `set_limit(link, kind, ms)` makes the loop watch a link and deliver the event `Expired` once when the link has been too long in one state: `Idle` (no byte either way), `Silent` (nothing received), `Stalled` (bytes waiting and the peer not reading), `HalfOpen` (one stream ended) or `Age` (since it opened). It counts the bytes a relay carries, and leaves the closing to the library.
- Add the compile-time check of each (`require_relay`, `require_peek`, `require_revoke`, `require_wake`, `require_limits`) and the three new events `Input`, `Woken` and `Expired` to `Event`.
- **BREAKING (compile time only):** a `match` on `Event` with no `_` arm must name `Input`, `Woken` and `Expired`, as it already had to name `PassEnd`. No behaviour of a loop that does not supply the groups changes.
- Add a conformance entry point for each group, an implementation of each in the in-memory loop, and a fault for every check.

Out of scope: implementing the groups on a real loop (`goose-io-epoll-ext`, a future io_uring loop) and in tcprouter, which is separate work done after the loops and tcprouter port exist without groups; files, loans, parts and addresses (`add-stream-extras`), handing a link to another thread or process, datagrams, TLS and kernel TLS, per-socket tuning (configuration of the loop, set when the application constructs it), and tcprouter's audit and port.

## Capabilities

### New Capabilities

None. The groups extend the contract and the suite that already exist.

### Modified Capabilities

- `io-contract`: the contract gains five groups and three events; the requirement that names the groups and the one that checks them change, and each group has requirements of its own.
- `provider-conformance`: the suite gains an entry point and checks for each group, and the in-memory loop supplies each group with a fault for each check.

## Impact

- **goose-io code:** `goose_io.goose` (types, events, `require_*` checks, version 0.3), `memory.goose` (the groups and faults), `conformance/` (checks), `tests/conformance/` (table, group check, runner), `docs/contract.md`, `docs/libraries.md`, `docs/event-loops.md`. The pure-Goose rule is kept: no C in the package.
- **Libraries:** none changes; an exhaustive `match` on `Event` gains three arms (the example libraries already end in `_ =>` or `PassEnd`).
- **Event loops and tcprouter:** unchanged by this change. Loops implement a group, and tcprouter uses one, in later work.
- **Order:** applies after `epoll-event-loop` is accepted and the loops and tcprouter port exist without groups; `add-stream-extras` applies after this.
- **Toolchain:** Goose v2026.4, Linux for the epoll loop; no new dependencies.
