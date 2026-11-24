## Context

A link belongs to one loop for its life (core). tcprouter runs one loop. The wake capability already carries 64 bytes between threads (`wake_with`, `Woken.body`), enough for a ticket. Linux lets a descriptor move between epoll sets or io_uring rings of one process at no cost beyond the registration, so handing off costs little on a real loop.

## Goals / Non-Goals

**Goals:**

- Move a connection between loops of one process without relaying it.
- Keep the order of bytes across the move, and lose none that were received.
- Keep the core's rule that `Closed` is a link's last event: the old link closes, the new one opens.

**Non-Goals:**

- Moving to another process or another kind of loop.
- Moving a link's settings.

## Decisions

### D1. Close on one side, open on the other

Treating the move as a `Closed` and an `Opened` keeps every core rule about a link's life, and both libraries handle the move with the events they already handle. *Alternative:* a `Moved` event and the same handle on both loops. Rejected: handles are per loop.

### D2. A new close reason

The first library must know the connection did not end, so as not to log or count it as closed. `HandedOff` adds one enum value. A library with a default arm needs no change.

### D3. A ticket is a value

Loops on different threads share nothing. A small value that the wake body can carry is enough, and the process-wide table behind it is the loop's.

### D4. Received bytes move

A request that arrived just before the move belongs to the adopting library. Dropping it would make hand-off unusable after reading the first line, which is the common case.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_link_handoff<Io>(io: Io&) -> Absent` and a query `fn has_link_handoff<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_link_handoff(io: Loop&) -> goose_io::Supplied`. `require_link_handoff` names `hand_off`, `adopt` and `drop_ticket` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_link_handoff(w.inner)`.

An application uses it optionally: the `Supplied` branch runs an acceptor that hands links to workers; the other serves every link on the loop that accepted it (or, with shared-listen, lets each worker accept its own). The example has both.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/link-handoff.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `hand_off`, `adopt`, `drop_ticket`, `Ticket` and `HandedOff`, and what moves with a link; links to the normative section.
- **When to use it:** a connection must be served on a loop chosen after it was accepted (by tenant, by session, by load), or a loop that drains gives its links away. When not: any loop can serve any connection (shared-listen), or one loop can relay for the link's life cheaply.
- **How it is commonly used:** accept, read the first request, hand off, send the ticket with `wake_with`, adopt in the worker's `Woken` handler, set limits at `Opened`; mistakes: counting `HandedOff` as a close, expecting settings to move, leaking tickets on shutdown.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/acceptor_workers.goose`, a small library (an acceptor loop that reads a tenant name from the first line and hands each link, with its ticket in `wake_with`, to the worker loop that owns the tenant), and its test `tests/examples/capabilities/acceptor_workers_test.goose`, which runs on the in-memory loop, with two in-memory loops.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_link_handoff`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (moving the descriptor between epoll sets or io_uring rings in one process; a link table between in-memory loops), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A ticket lost between threads leaks a connection] → tickets of a stopped loop are closed; the in-memory fixture reports open tickets at the end of a test, and the example's test asserts none.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. A library that matches `CloseReason` with no default arm adds `HandedOff`. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should a library be able to carry a little state with the ticket? The wake body has room (64 bytes less the ticket); left to the library.
