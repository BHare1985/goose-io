## Context

Section 11 of `docs/contract.md` lists in-place writing as uncovered: "`Data` lends read-only bytes. Can be relaxed later." The research attached to this proposal (its "MutableRecv") and the uSockets mapping document show that every candidate loop reads into a buffer it owns and could lend it writable. Goose's `const u8[:]` on `Data` is what makes the bytes read-only. Changing the event's field type would break every library, so this capability adds an operation instead.

## Goals / Non-Goals

**Goals:**

- Let a library transform received bytes without copying them first.
- Keep `Data` unchanged, so no library's code changes.

**Non-Goals:**

- Writable peek bytes, or changing the length of the bytes.
- Promising that a write is visible to any other operation except `retain` when retained-data is supplied.

## Decisions

### D1. An operation, not a second event or a field type change

Making `bytes` writable would change `Data` for every library. A `DataMut` event would split every handler. `data_mut(link)` returns the same buffer, writable, only to a library that asks. *Alternative:* a loop configuration flag. Rejected: the library, not the application, knows it transforms bytes.

### D2. Writes are local

A loop may deliver one buffer to a relay, a peek and a library in turn. Promising that writes reach nothing else keeps the capability simple to supply, and the only composition promised is with `retain`, where the library asks for exactly those bytes.

### D3. A copy conforms

A loop whose receive buffer is shared read-only copies into a scratch buffer for `data_mut`. The library saves nothing then, but it runs, and the page says which loops lend without a copy.

### D4. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_mutable_data<Io>(io: Io&) -> Absent` and a query `fn has_mutable_data<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_mutable_data(io: Loop&) -> goose_io::Supplied`. `require_mutable_data` names `data_mut` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_mutable_data(w.inner)`.

A library uses it optionally: in its `Data` handler, the branch for `Supplied` transforms `io.data_mut(link)` in place, and the other branch copies `bytes` into its buffer and transforms the copy. One transform function takes a `u8[:]` and serves both.

### D5. Documentation: the capability's page

The change adds `docs/capabilities/mutable-data.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `data_mut`, the lifetime of the bytes it lends, and the rule that writes reach only the library; links to the normative section.
- **When to use it:** every received byte is transformed before use: WebSocket unmasking, in-place decryption, byte-order or charset translation, a header rewrite before a retained send. When not: bytes kept unchanged (use `Data` or retained-data), or only a few bytes changed (copy them).
- **How it is commonly used:** unmask or decrypt in the `Data` handler, then parse the result; with retained-data, transform then `retain` to keep the plaintext; mistakes: expecting the change to reach the peer, keeping the slice past the handler.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/unmask.goose`, a small library (a WebSocket-style frame reader that unmasks payloads in place, and copies first on a loop without the capability), and its test `tests/examples/capabilities/unmask_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_mutable_data`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (the loop's own read buffer in every candidate loop; a copy where the buffer is shared read-only), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [Writes surprise a library that shares a handler with relay or peek] → the rules say writes reach nothing but the handler, and the suite checks `peek` and the next `Data` after a write.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should `peek` also lend writable bytes, for a library that unmasks before it chooses a handler? Not until one needs it.
