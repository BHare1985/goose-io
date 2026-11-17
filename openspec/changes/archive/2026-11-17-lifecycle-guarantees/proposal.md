# Proposal

## Why

The contract states what a link does on its common paths. It says less about the edges, and the first loops on real sockets (the `epoll-event-loop` change, then io_uring) will each fill those gaps in their own way unless the contract fills them first. The gaps are these:

- **Calls in unusual states.** The result of a link operation is stated for an open link and for a stale handle. In the other states it is stated in some places and not in others: `pause_reading` on a dial in progress, `reset` before `Opened`, `shutdown_write` after `close`.
- **Two rules that depend on timing or contradict each other.**
  - `set_keep_open_on_eof` works "before the peer's end of stream", so whether a late call works depends on when a loop happens to notice that end of stream.
  - `peer_address` is "empty for a link that is not open" but also "available until `Closed` is delivered". The two disagree on a closing link.
- **How each operation completes.** Some operations are finished when they return (`send`, `pause_reading`) and others are followed by an event (`dial`, `close`, `stop`). The contract shows this by example and does not list it.
- **Whether a handle can come back.** In the in-memory loop, a slot's generation wraps from `0xffffffff` back to 1 (`memory.goose:963`). After 2^32 reuses of one slot, a stale handle can reach a new link. No rule forbids this, and none says that a slot stays with a link until its `Closed` is delivered.
- **A loop after `serve`.** A loop whose `serve` has returned "is not run again", but nothing says what its operations do after that.
- **Bytes at the end of the grace period.** The contract does not say whether accepted bytes are delivered, or which reason a link gets when the library had closed it and it is still sending when the grace period ends.
- **Which thread may set a loop up.** "Before `serve`" does not say on which thread.

The comparison with Mio, libuv, libevent and µSockets points at the same places: Mio for exact registration guarantees, libuv for the difference between a long-lived handle and the operations on it. Most of the other suggestions are already in the contract and need no change:

- one thread, with no events delivered from inside an operation;
- `Sent` means the bytes were taken, not that the peer received them;
- `close` keeps accepted bytes;
- groups serve as capability discovery;
- a conformance suite that is neutral about the event loop;
- read interest through `pause_reading`, write interest through `Full` and `Writable`;
- buffer lending, so no copy is forced.

## What Changes

- **Link states.** Name the states of a link as a library sees them: dialling, open, write-shut, closing, ended. For every link operation of the core and of each group, state the result in every state. This goes into `docs/contract.md` as one table, and into the spec as one requirement for each family of rows.
- **Keep-open window.** `set_keep_open_on_eof` takes effect only while dialling or inside the link's `Opened` handler, and applies when that handler returns. A later call has no effect, and a loop that saw the end of stream early waits until the handler has returned. This is a tightening: in-repo callers that set it later move into `Opened`.
- **`peer_address`** gives the address while open, write-shut or closing, and is empty while dialling and once ended.
- **A `Closed` send result is final for sending:** no later send is taken, and no `Writable` follows. When the library had not shut or closed the link, it also means the link is ending and its `Closed` follows. After `shutdown_write` it means only that sending has ended.
- **Completion.** List, for each operation, what it returns with and its one later notification, if it has one. A `Tick` may answer several `tick_by` calls.
- **Handles.**
  - Reserve `Link {}` (generation 0) as the invalid link of every loop.
  - Forbid issuing a slot and generation pair twice: a slot whose generations are used up is retired, not wrapped.
  - Forbid issuing a link in a slot whose previous link's `Closed` has not been delivered.
- **The life of a loop.** Name its states: set up, serving, draining, finished. On a finished loop:
  - sends return `Closed`, and `listen` fails with kind `Other`;
  - `dial` returns the invalid link, issuing nothing (the one exception to "dial always ends in one event");
  - a second `serve` returns at once;
  - nothing crashes or blocks.
- **Threading.** A loop belongs to the thread that calls `serve`, and the application makes every call on that thread, before `serve` as well.
- **End of the grace period.** No promise that accepted bytes reach the peer: the loop may discard them and end the link gracefully or by abort. A link the library closed, before or after `stop`, still ends with `Local`, never `Shutdown`.
- **Conformance checks,** each with a fault in the in-memory loop:
  - a states check in each group that has link operations (core, half-close, sizing, abort, inspection);
  - the keep-open window;
  - two handle checks run by the driver over every part, `handles_pair_unique` and `handles_slot_held`;
  - setup before `serve`, and a finished loop;
  - `Local` over `Shutdown`, in both orders.
- **Docs and version.** Update `docs/contract.md`, `docs/event-loops.md` and `docs/libraries.md`, and raise the minor version.

Out of scope, recorded as later changes:

- **A runtime contract monitor.** A pure-Goose observer that checks event-side rules continuously over real workloads and gives a portable count of links by state, listeners and owed `Writable` events. This is the diagnostics suggestion without new event-loop operations. It cannot be a wrapping layer: Goose does not allow a root struct inside another struct (checked with a compile test), so its shape needs its own design.
- **A varying mode for the in-memory loop.** A seeded mode that changes what the contract leaves open: how `Data` is split, the order across links in one pass, the choice between `Writable` and `Closed`. It finds libraries that depend on one loop's incidental behaviour.

Rejected for the contract:

- **A descriptor-readiness capability.** It conflicts with *The contract exposes no operating-system primitives*: an in-memory, completion-only or userspace-stack loop has no descriptors. It stays an open question in `docs/contract.md` section 12, as a loop-specific extension outside the contract.
- **A wake from another thread.** It stays a later optional group.
- **New send results or error codes.** `shutdown_write` keeps returning `Closed`, and a late keep-open call is silently ignored rather than reported. The contract gives no meaning to a `ListenError` code.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`:
  - modifies *A link reports its peer's address* (closing links name their peer, and dialling links are empty);
  - adds requirements for link states and each operation's result in them, the keep-open window, the finality of a `Closed` send result, completion, the reserved invalid link, pair uniqueness, slot holding, loop states and a finished loop, the thread that owns a loop, and the end of the grace period.
- `provider-conformance`: adds the states checks for each group, the driver's two handle checks, the loop-life checks, and the in-memory loop's retirement of an exhausted slot.

## Impact

- **goose-io:**
  - `memory.goose`: slot retirement, the keep-open window, behaviour after `serve`, a fault for each new check, and a test hook that ages a slot's generation;
  - `conformance/`: the new checks, plus the driver's record of issuances and its pre- and post-`serve` steps; the two existing checks that set keep-open late move it into `Opened`;
  - `tests/conformance/checks.tsv` and `tests/unit/`, including the tests that set keep-open late;
  - `tests/support/kit.goose`, `core_only.goose` and `wrapper.goose`;
  - `docs/contract.md`, `docs/event-loops.md`, `docs/libraries.md`, and `goose_io.goose` (the version).
- **Event loops:** no signature changes. The new obligations are retiring slots, holding a slot until `Closed`, the keep-open window, finished-loop behaviour and `Local` over `Shutdown`. Each is a few lines in the in-memory loop.
- **Libraries:** no source changes, except that a library setting keep-open after `Opened` must move the call. The example line server already sets it in `Opened`.
- **Other changes:**
  - This change is written against the contract as `link-keyed-state` leaves it, so its tables do not mention `tag`, `user` or `set_user`. If it is applied first, `set_user` gets the row of `pause_reading` and `user` the row of `peer_address`.
  - It modifies only *A link reports its peer's address*, which `link-keyed-state` does not touch, so the two changes do not conflict. Retired slots do interact with that change's dense-slot rule (see `design.md`).
  - `epoll-event-loop` inherits the new obligations. It is not edited here.
