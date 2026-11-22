## Why

After `add-proxy-groups`, the contract can express everything tcprouter needs. Other stream programs meet four more gaps: an HTTP or file server cannot send a file without reading it into memory or send header and body and a third part without joining them, a program that wants to send without a copy cannot lend a buffer to the loop, and a transparent proxy or an access log cannot ask for the loop's own address or the address the peer originally connected to. Each has a kernel mechanism behind it (`sendfile`, `writev`, `MSG_ZEROCOPY`, `getsockname`, `SO_ORIGINAL_DST`). This is the second pass: the four capabilities are specified now so that the contract's list of capabilities is complete when tcprouter's audit runs, and implemented on a real loop only as far as a user appears.

## What Changes

- Add four optional capabilities to the contract (the core and the eleven capabilities after `add-proxy-groups` are unchanged):
  - **files**: an opaque `File`, `open_file`, `close_file` and `send_file(link, file, offset, len)`, which sends a range of a file as `send` does.
  - **loans**: `loan(size)`, `loan_bytes`, `send_loan(link, loan, len)` and `release_loan`: a send from a buffer the loop lent, so the loop may send it without copying.
  - **parts**: `send_parts(link, parts)`, `send2` for any number of parts.
  - **addresses**: `local_address(link)` and `original_destination(link)`.
- Add the compile-time check of each (`require_files`, `require_loans`, `require_parts`, `require_addresses`), the declaration and query of each (`supplies_<c>`, `has_<c>`, from `rename-groups-to-capabilities`), and the two new handle types `File` and `Loan`. Raise the contract's minor version by one.
- Make files, loans and parts usable optionally: each has a core path that puts the same bytes on the wire. A new example, `examples/capabilities/static_files.goose`, takes both paths and is tested on the in-memory loop and on the core-only loop.
- Add a page for each of the four in `docs/capabilities/` (from `document-capabilities`): what it is, when to use it, how it is commonly used, checked examples, and a row in the index.
- Add a conformance entry point for each capability, an implementation of each in the in-memory loop (a file is a byte range the test registers), and a fault for every check.

Out of scope: implementing the capabilities on a real loop, and everything out of scope in `add-proxy-groups` (handing a link on, datagrams, TLS, per-socket tuning). Several of those are now proposed as capabilities of their own.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: the contract gains four capabilities and two handle types; the requirement that names each capability by its parts changes again (to fifteen), and each capability has requirements of its own.
- `contract-documentation`: the four capabilities get pages (after `document-capabilities` adds that spec).
- `provider-conformance`: the suite gains an entry point and checks for each capability, and the in-memory loop supplies each with a fault for each check.

## Impact

- **goose-io code:** `goose_io.goose` (types, `require_*` checks, declarations and queries, the minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `docs/`, `docs/capabilities/` (four pages and the index), `examples/capabilities/static_files.goose` and its tests. Pure Goose.
- **Libraries:** none changes. No new event is added, so no match on `Event` is affected.
- **Event loops:** unchanged; a loop implements a capability in later work, and the mapping documents of the candidate loops gain a row for each capability.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are applied and accepted. Its modified requirements replace the rename's.
- **Toolchain:** none new.
