## Why

A server whose clients always speak first (HTTP, a line protocol, TLS) gains nothing from a link that has connected and sent nothing: it costs an `Opened`, a slot and a timer, and a flood of empty connections costs that many times over. Linux `TCP_DEFER_ACCEPT` and FreeBSD's `SO_ACCEPTFILTER` (`dataready`, `httpready`) keep such a connection in the kernel until bytes arrive, so the server is woken only for connections with something to read. The research behind this proposal called it "DeferredAccept" or "AcceptFiltering".

## What Changes

- Add the deferred-accept capability: `defer_accept(listener, ms)` asks the loop to deliver a link's `Opened` only once its first bytes have arrived, or `ms` after it connected, whichever comes first. The bytes are delivered as `Data` in the same pass as `Opened`.
- State that a user-space hold conforms: a loop without a kernel filter accepts and holds the link without telling the library.
- Declare the capability as every capability is declared (`supplies_deferred_accept` and `goose_io::has_deferred_accept`, from `rename-groups-to-capabilities`), with a compile-time check `require_deferred_accept` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (a hold on the virtual clock), and a named fault for every check.
- Add `docs/capabilities/deferred-accept.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/deferred_server.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: protocol-aware filters (`httpready`), and a timeout that drops the connection silently (the loop delivers `Opened` at the timeout; the library's `Silent` limit or its own deadline closes it).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the deferred accept capability: the operation `defer_accept(listener, ms) -> bool`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the deferred accept suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/deferred-accept.md` exists and covers what deferring saves, which protocols it suits (client speaks first), and what happens at the timeout.

## Impact

- **goose-io code:** `goose_io.goose` (`defer_accept`, the declaration and query, `require_deferred_accept`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`TCP_DEFER_ACCEPT` on Linux, `SO_ACCEPTFILTER` `dataready` on FreeBSD, a user-space hold elsewhere).
- **Documents:** `docs/capabilities/deferred-accept.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
