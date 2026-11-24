## Why

`Data` lends bytes only until the handler returns, so a library that must keep them (a parser waiting for the rest of a frame, a proxy that forwards a request after choosing its backend, a cache filled from a response) copies them into a buffer of its own. On a loop that reads into buffers it owns, such as io_uring with provided buffer rings, DPDK mbufs or Seastar's `temporary_buffer`, the copy is the only one on the receive path. Keeping the loop's buffer instead saves it. `add-stream-extras` adds loans, the send side of the same idea. This is the receive side. The research notes behind this proposal called it "RetainedRecv". The coroutine question of `docs/contract.md` section 12 (how a `Data` slice maps onto a resume value) also needs bytes that outlive a handler.

## What Changes

- Add the retained-data capability: inside the handler of a `Data`, `retain(link)` keeps that event's bytes beyond the handler and returns a `Retained` handle, or an invalid handle when the loop's bound `max_retained()` would be exceeded.
- `retained_bytes(r)` returns the kept bytes, unchanged, until `release(r)`. `send_retained(link, r, offset, len)` sends a range of them as `send` does, so a library can pass bytes through without copying them.
- State that a copy conforms: a loop that reads into one reused buffer copies on `retain`, and the capability still saves the library's own buffer management.
- Declare the capability as every capability is declared (`supplies_retained_data` and `goose_io::has_retained_data`, from `rename-groups-to-capabilities`), with a compile-time check `require_retained_data` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (a bounded store; a copy conforms), and a named fault for every check.
- Add `docs/capabilities/retained-data.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/frame_reassembly.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: the send side (loans, in `add-stream-extras`), writing into received bytes (`add-mutable-data`), a loop-wide buffer pool API, and retaining bytes withheld by peek (they stay with the loop until `peek` or `relay` already).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the retained data capability: the operations `retain(link) -> Retained`, `retained_bytes(r) -> const u8[:]`, `send_retained(link, r, offset, len) -> SendStatus`, `release(r)` and `max_retained() -> i64`, and the handle type `Retained`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the retained data suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/retained-data.md` exists and covers what retaining keeps and for how long, the bound and what to do when `retain` fails, and when retaining beats copying.

## Impact

- **goose-io code:** `goose_io.goose` (the handle `Retained` and the five operations, the declaration and query, `require_retained_data`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A library that keeps bytes may retain them when the loop supplies the capability and copy them otherwise.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (io_uring provided buffer rings, DPDK mbuf references, a copy into a loop-owned store elsewhere).
- **Documents:** `docs/capabilities/retained-data.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
