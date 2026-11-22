## Context

`dial(address, connect_ms)` returns a link and its bytes can be sent only after `Opened` (a `send` before it is held). TCP Fast Open needs the bytes at connect time, so no use of today's operations can reach it. RFC 7413 states the replay risk this change carries over. The research attached to this proposal paired this with TLS and QUIC 0-RTT. Both live above or beside a stream contract.

## Goals / Non-Goals

**Goals:**

- Save a round trip for a client's first repeat-safe request.
- Make the replay risk part of the contract, so a library author cannot miss it.
- Conform on loops without Fast Open by sending at open.

**Non-Goals:**

- Telling the library whether bytes rode the opening: a library must assume they may have.
- Server-side detection of replays: a protocol's business.

## Decisions

### D1. A new dial operation, not an option on dial

`dial` is core and unchanged. `dial_with_data` adds one argument. *Alternative:* `send` before `Opened` becomes early. Rejected: it would change the core's meaning for every library, and the replay risk must be asked for.

### D2. Sending at open conforms

The requirement states order, not mechanism. A loop without Fast Open dials and sends `first` when the link opens, which is what the library would have done itself.

### D3. The server opts in

A server that never asked receives the bytes after the handshake, as today. `accept_early_data` is what tells the system to take bytes off the SYN, and it is the server library that knows its protocol tolerates repeats.

### D4. Bounded by the loop

Fast Open carries one segment's worth at most. `max_early_data()` makes that the library's limit, and refusing a longer `first` keeps the operation all or nothing, like `send`.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_early_data<Io>(io: Io&) -> Absent` and a query `fn has_early_data<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_early_data(io: Loop&) -> goose_io::Supplied`. `require_early_data` names `dial_with_data`, `max_early_data` and `accept_early_data` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_early_data(w.inner)`.

A client library uses it optionally: the `Supplied` branch calls `io.dial_with_data(addr, ms, request)`, the other calls `io.dial(addr, ms)` and sends `request` at `Opened`. The server side is optional in the same way: without the capability the listener simply receives the bytes after the handshake.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/early-data.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `dial_with_data`, `max_early_data` and `accept_early_data`; the order rule and the replay rule; links to the normative section.
- **When to use it:** a client that reconnects often and whose first request is safe to repeat (a GET, a health check, a cache lookup). When not: a first request that changes state (a POST, a payment), long-lived connections where one round trip does not matter, or a server that never opted in.
- **How it is commonly used:** dial with the request and handle `Opened` and the reply as usual; on the server, opt in once after `listen`; mistakes: sending a state-changing request early, expecting early bytes to bypass the bound.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/early_get.goose`, a small library (a client that sends a repeat-safe request with `dial_with_data` and a server listener that accepts early data), and its test `tests/examples/capabilities/early_get_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_early_data`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`TCP_FASTOPEN`/`MSG_FASTOPEN` and `TCP_FASTOPEN_CONNECT` on Linux, `connectx` with `CONNECT_DATA_IDEMPOTENT` on macOS, a send at open elsewhere), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A library sends a non-idempotent request early] → the requirement and the page state the replay rule, and the example sends only a read.
- [Middleboxes drop SYNs with data] → the system falls back to a normal handshake, and the order rule still holds; nothing for the contract to do.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should a link report how many of its first bytes went early? Not on Linux without parsing `TCP_INFO`; left until a library asks.
