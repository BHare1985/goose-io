# Proposal

## Why

Every link event carries two values the application or a library attached from outside: a 16-bit `tag` (given to `listen` and `dial`, says which library owns the link) and a 32-bit `user` value (set with `set_user`, says which of that library's records the link is). Both are the same thing, "caller context bolted onto a handle", and each costs something:

- A library starts every handler arm with `if e.tag != s.tag { return false; }`, then looks up a record by `e.user`, then checks `same(link)` anyway because the index cannot be trusted. The tag check is redundant for every event but `Opened`: the lookup already rejects a link that is not in the library's table.
- `set_user` is a second call after `dial` and after every `Opened`. A dial that fails inside `dial` queues its `Closed` before the value is set, so the contract needs a special rule (the value is read when the event is delivered) and the engine notes carry a known defect about it (`docs/event-loops/tcprouter-engine.md`, item 1).
- `user` is both an operation (inspection group) and an event field, and `tag_of` and `user_of` repeat the same five-arm match.
- Neither is what ZeroMQ's poller does. `zpoller_wait` returns the registered object, and the caller compares it with `frontend` or `backend`. There is no tag and no number to set: the identity of the thing is the key.

A `Link` already is that identity: it has `slot: u32`, a small number the loop assigns, and a generation. A library can keep its own state in a table indexed by `link.slot` and let the generation reject stale and foreign handles. An accepted link already names the listener that took it (`Opened.listener`), and a dialled link was returned to the library by `dial` before any event about it. So nothing needs to be attached at all.

## What Changes

- **BREAKING** Remove `tag` and `user` from `Opened`, `Data`, `Writable`, `PeerEof` and `Closed`; remove `tag_of` and `user_of`; remove the `tag` parameter of `listen` and `dial` (`listen(address)`, `dial(address, connect_ms)`); remove the core operation `set_user` and the inspection operation `user`. The core becomes twelve operations; the inspection group becomes `peer_address` and `stop_listening`.
- A link event is recognised by what already identifies it: a dialled link by the `Link` the library holds, an accepted link by `Opened.listener` (the library compares it with the listeners it started), and every later event by the library's own state keyed by the link.
- Add a contract guarantee on slot numbers: a loop SHALL reuse a freed slot before it hands out a new one, so no slot number is ever at or above the greatest number of links valid at once **on that loop**. This bounds a slot-indexed table by the loop's peak, which is every library's links together, not by one library's own peak: a library with two links can hold a link whose slot is 100,000 if other libraries hold the rest. The event loop passes nothing in. The rule is one this change adds so that a table indexed by slot stays bounded; it is not a property every event loop has by nature, and an author of a new loop is told why it is there.
- Add `LinkMap<T>` to the contract package: a generic, pure-Goose table keyed by `Link`, flat (one value and one generation for each slot up to the highest the library has used), built on grow-only arrays so a reference into it stays valid, with the generation stored beside each value so a stale or foreign link finds nothing. A library declares `LinkMap<Conn>` and never handles a slot number or a generation. Its cost is stated, not hidden: memory is the loop's peak slot count times the size of the library's state (measured in `bench/link_map_bench.goose`; about 0.5 MiB for 1,024 slots of 512-byte state, 49 MiB for 100,000 slots of 512-byte state). `LinkMap` is a helper and no library has to use it: a library may keep its state any way it likes, including a table of its own with another layout (for example one that stores values only for its own links), because the contract guarantees the link's identity and lifetime and not the table.
- Replace the conformance checks `owner_tags`, `owner_user_value`, `owner_user_after_failed_dial` and `handles_stale_user` with checks of what replaces them: the accepted link names its listener, a dial that fails at once still finds its link, and slots are dense. A stale handle finding nothing in a `LinkMap`, and a library claiming only the events of links it owns, are shown by unit tests and by tests of the example libraries. Replace the old faults.
- A library claims an event only when it owns the link: for `Data`, `Writable`, `PeerEof` and `Closed` that means it has state for the link, and a library that does not returns "not handled", where today the examples return "handled" after a tag matches even when the lookup finds nothing.
- Change the examples (`lineserver`, `lineclient`), `docs/libraries.md`, `docs/contract.md`, `docs/event-loops.md`, `README.md` and the in-memory loop to match. Raise the version to 0.2, the release after 0.1 on `main`, shared with `add-unix-sockets` and `lifecycle-guarantees` (the major number is zero, so a minor increase may remove behaviour).

Out of scope: any socket-backed event loop (the `epoll-event-loop` change owns it), changes to libraries outside this repository (they get a migration note), a new way to attach arbitrary data to a link (the point is that the library's own table is that place), and cross-library sharing of one table.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: rewrites the owner requirement, the handle requirement, listening and dialling (no tag), the core's operation list and the inspection group; adds the dense-slot guarantee, `LinkMap` and the rule that a library claims only events of links it owns.
- `provider-conformance`: replaces the listener-overlap scenario's tag wording, and adds the checks that replace the owner and user checks (those about the event loop; the ones about a library are shown by unit and example tests).

## Impact

- **goose-io:** `goose_io.goose` (types, helpers, `LinkMap`, `require_core`, `require_inspection`, version), `memory.goose` (events, `listen`, `dial`, slot reuse, the removed operations and faults), `conformance/*`, `tests/` (every test that reads `tag` or `user`, the check table, the core-only loop and the wrapper), `examples/lineserver`, `examples/lineclient`, `docs/*`, `README.md`.
- **Event loops and libraries:** every event loop and every library breaks at compile time (a signature and an event field change); the error names the operation. Migration is mechanical and described in `design.md`. No library is in this repository besides the two examples.
- **Other changes:** `epoll-event-loop` (46 open tasks) has the tag and user in its design and tasks; it is not edited here, and its owner updates it when this is applied. It also gains an obligation: slots must be reused before new ones are issued. `lifecycle-guarantees` is written against the contract as this change leaves it and owns the rules that a generation is never issued twice for a slot and that a slot is not reissued before its `Closed` is delivered; this change relies on them (see the design, *A library cannot be handed another library's state*), and states the second one itself where the dense-slot rule needs it.
- **Benchmark:** `bench/link_map_bench.goose` (new) measures the flat layout against a compact one and is written so the contract package's `LinkMap` can be added as a third arm; `README.md` lists `bench/`.
- **Risk:** the dense-slot guarantee is new for a loop to keep; a loop that cannot (an io_uring fixed-file table is dense already, an epoll loop with a freelist is) cannot conform. The contract states it as a requirement and the suite checks it. The flat map reserves memory for slots other libraries use; the design states the cost and the way out (a library's own table).
