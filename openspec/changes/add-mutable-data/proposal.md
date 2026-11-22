## Why

`Data` lends read-only bytes, and `docs/contract.md` section 11 records "writing into received bytes in place (WebSocket unmasking)" as a need that "can be relaxed later". A WebSocket server unmasks every client frame. A TLS library decrypts records in place. A proxy rewrites a header field before passing bytes on. A protocol translator swaps byte order. On today's contract each copies the bytes into a buffer of its own first, only to change them. Every loop that reads into its own buffer (io_uring registered or provided buffers, uSockets' receive buffer, the epoll loop's read buffer) could lend those bytes writable instead. The research notes behind this proposal called it "MutableRecv".

## What Changes

- Add the mutable-data capability: `data_mut(link)`, called while the loop delivers a `Data` for that link, returns the same bytes as the event's `bytes`, writable, valid until the handler returns.
- State what writes reach: the bytes the library changes are its own to read until the handler returns, and, when retained-data is also supplied, a `retain` after the writes keeps the changed bytes. No write reaches the peer, peek or another link.
- Declare the capability as every capability is declared (`supplies_mutable_data` and `goose_io::has_mutable_data`, from `rename-groups-to-capabilities`), with a compile-time check `require_mutable_data` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (its delivery buffer lent writable), and a named fault for every check.
- Add `docs/capabilities/mutable-data.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/unmask.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: writing into bytes held by peek, growing or shrinking the bytes, and in-place sending (`send_retained` of changed bytes needs retained-data, which composes with this).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the mutable data capability: the operation `data_mut(link) -> u8[:]`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the mutable data suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/mutable-data.md` exists and covers which bytes `data_mut` lends, how long they stay writable, what writes do and do not reach, and when changing bytes in place beats copying.

## Impact

- **goose-io code:** `goose_io.goose` (`data_mut`, the declaration and query, `require_mutable_data`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A WebSocket or TLS library may unmask or decrypt in place when the capability is supplied and copy otherwise.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (the loop's own read buffer in every candidate loop; a copy where the buffer is shared read-only).
- **Documents:** `docs/capabilities/mutable-data.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
