## Why

Many useful C libraries own their sockets and only ask the host "tell me when this descriptor is readable or writable": libpq, hiredis, libcurl's multi interface, c-ares, libmosquitto, librdkafka's queues. `docs/contract.md` section 11 records that hosting them "cannot be in the contract: an in-memory or completion-only event loop has no descriptors. A later optional capability." As an optional capability it costs loops without descriptors nothing: they do not declare it. Every readiness loop has it at the cost of one registration (epoll, kqueue), and an io_uring loop has it through poll requests. The research behind this proposal called it "ForeignPoll".

## What Changes

- Add the descriptor-readiness capability: `watch_descriptor(fd, interest)` registers a descriptor the library owns and returns a `Watch`. The loop delivers `Ready` once when the descriptor becomes readable or writable, as `interest` asked, or fails.
- Readiness is one-shot: after `Ready`, the library calls `arm(watch, interest)` to be told again, which is how C libraries' callbacks ask for reads and writes. `unwatch(watch)` ends it, and must come before the library closes the descriptor.
- State that the loop never reads, writes or closes a watched descriptor.
- Declare the capability as every capability is declared (`supplies_descriptor_readiness` and `goose_io::has_descriptor_readiness`, from `rename-groups-to-capabilities`), with a compile-time check `require_descriptor_readiness` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (simulated descriptors a test marks ready), and a named fault for every check.
- Add `docs/capabilities/descriptor-readiness.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/foreign_client.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: timers for C libraries (they use `tick_by` and `Deadlines`), descriptors that are not sockets or pipes, signals, and adapting a C library's own event-loop API (each adapter is a library on this capability).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the descriptor readiness capability: the operations `watch_descriptor`, `arm` and `unwatch`, the event `Ready`, and the types `Watch` and `Interest`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the descriptor readiness suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/descriptor-readiness.md` exists and covers one-shot readiness and re-arming, who owns the descriptor, how a C library's add/remove callbacks map onto `arm` and `unwatch`, and what it costs a loop.

## Impact

- **goose-io code:** `goose_io.goose` (the types `Watch` and `Interest`, the event `Ready` and the three operations, the declaration and query, `require_descriptor_readiness`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A library that wraps a C client depends on the capability, or uses it optionally and refuses to start without it.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`EPOLLONESHOT` on epoll, `EV_DISPATCH` on kqueue, `IORING_OP_POLL_ADD` on io_uring; not the in-memory loop with real descriptors).
- **Documents:** `docs/capabilities/descriptor-readiness.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
