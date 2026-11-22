## Context

`Data { link, bytes: const u8[:] }` lends bytes valid until the handler returns (`goose_io.goose`, the comment on `Data`). Libraries keep what they need by copying: the line server buffers partial lines, and tcprouter's gateway copies the first request before relaying. The research attached to this proposal names the loops where the copy is the only one: io_uring multishot receive with provided buffer rings, DPDK mbufs, Seastar. The uSockets mapping document (row `Data`) shows the opposite: one receive buffer for the loop, reused at once, where retaining is a copy. `add-stream-extras` gives the send side (`loan`).

## Goals / Non-Goals

**Goals:**

- Let a library keep received bytes without copying them on loops whose buffers allow it.
- Bound what is kept, so a slow library cannot exhaust the loop's buffers silently.
- Let kept bytes be sent on as they are (pass-through).

**Non-Goals:**

- A buffer pool API, chained buffers or scatter lists of retained ranges.
- Retaining part of a `Data`: the library sends a range with `send_retained` and the whole event is kept.

## Decisions

### D1. Retain is an operation called in the Data handler

The handler is the only time the loop knows the buffer is the library's to keep. An operation called there, rather than a flag on `Data`, leaves the event unchanged, so no library's match changes. *Alternative:* a `DataRetained` event. Rejected: every library that handles `Data` would see a second event kind.

### D2. A whole event is kept, and a range is sent

Keeping a sub-range would split a loop's buffer, which provided buffer rings cannot do. The library keeps the event and addresses ranges with `offset` and `len`.

### D3. A bound, and failure means copy

A retained buffer is a buffer the loop cannot reuse for reading. `max_retained()` makes the cost explicit. A failed `retain` leaves the event's bytes valid until the handler returns, so the library's other path is always available: the copy it would have made anyway.

### D4. A copy conforms

A loop with one reused buffer copies on `retain`. The library still gains a bounded store it does not have to manage, and the contract does not promise zero copies, only that the library need not copy.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_retained_data<Io>(io: Io&) -> Absent` and a query `fn has_retained_data<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_retained_data(io: Loop&) -> goose_io::Supplied`. `require_retained_data` names `retain`, `retained_bytes`, `send_retained`, `release` and `max_retained` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_retained_data(w.inner)`.

A library uses it optionally: in its `Data` handler it calls `retain` in the branch taken when `goose_io::has_retained_data(io)` is `Supplied`, and on the other branch, or when `retain` returns an invalid handle, it copies into its own buffer. The example has both paths, sharing one function that reads from either.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/retained-data.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `retain`, `retained_bytes`, `send_retained`, `release`, `max_retained` and the `Retained` handle; the lifetime rule; links to the normative section.
- **When to use it:** bytes that must outlive a handler: partial frames, requests forwarded after a decision, bodies stored in a cache. When not: a few bytes (copy them), bytes peek already holds, or a library that relays (it sees no bytes).
- **How it is commonly used:** retain partial frames and release when the frame is complete; `send_retained` to pass a request through; release in the handler of `Closed`; mistakes: retaining every `Data` of a busy link (the bound is shared by all links), forgetting to release, calling `retain` outside the handler.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/frame_reassembly.goose`, a small library (a length-prefixed frame reader that retains partial frames, sends complete ones on with `send_retained`, and copies on a loop without the capability), and its test `tests/examples/capabilities/frame_reassembly_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_retained_data`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (io_uring provided buffer rings, DPDK mbuf references, a copy into a loop-owned store elsewhere), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [Retained buffers starve reading] → the bound is the loop's, and `retain` fails before it is exceeded; the page tells libraries to release in `Closed`.
- [A leaked handle holds memory forever] → handles are generation-checked, and the in-memory loop's fixture can report retained bytes at the end of a test, which the example's test asserts is zero.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should the loop pause reading a link whose retained bytes pass a per-link share of the bound? Left to the loop's configuration until a real loop needs it.
- Should retained bytes be usable by `relay` or `send_file` style operations of other capabilities? Not until one needs it.
