## Why

After `add-proxy-groups`, the contract can express everything tcprouter needs. Other stream programs meet four more gaps: an HTTP or file server cannot send a file without reading it into memory or send header and body and a third part without joining them, a program that wants to send without a copy cannot lend a buffer to the loop, and a transparent proxy or an access log cannot ask for the loop's own address or the address the peer originally connected to. Each has a kernel mechanism behind it (`sendfile`, `writev`, `MSG_ZEROCOPY`, `getsockname`, `SO_ORIGINAL_DST`). This is the second pass: the four groups are specified now so that the contract's list of groups is complete when tcprouter's audit runs, and implemented on a real loop only as far as a user appears.

## What Changes

- Add four optional groups to the contract (the core and the eleven groups after `add-proxy-groups` are unchanged):
  - **files**: an opaque `File`, `open_file`, `close_file` and `send_file(link, file, offset, len)`, which sends a range of a file as `send` does.
  - **loans**: `loan(size)`, `loan_bytes`, `send_loan(link, loan, len)` and `release_loan`: a send from a buffer the loop lent, so the loop may send it without copying.
  - **parts**: `send_parts(link, parts)`, `send2` for any number of parts.
  - **addresses**: `local_address(link)` and `original_destination(link)`.
- Add the compile-time check of each (`require_files`, `require_loans`, `require_parts`, `require_addresses`), the two new handle types `File` and `Loan`, and raise the contract's version to 0.4.
- Add a conformance entry point for each group, an implementation of each in the in-memory loop (a file is a byte range the test registers), and a fault for every check.

Out of scope: implementing the groups on a real loop, and everything out of scope in `add-proxy-groups` (handing a link on, datagrams, TLS, per-socket tuning).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: the contract gains four groups and two handle types; the requirement that names the groups and the one that checks them change again (to fifteen), and each group has requirements of its own.
- `provider-conformance`: the suite gains an entry point and checks for each group, and the in-memory loop supplies each with a fault for each check.

## Impact

- **goose-io code:** `goose_io.goose` (types, `require_*` checks, version 0.4), `memory.goose`, `conformance/`, `tests/conformance/`, `docs/`. Pure Goose.
- **Libraries:** none changes. No new event is added, so no match on `Event` is affected.
- **Event loops:** unchanged; a loop implements a group in later work, and the mapping documents of the candidate loops gain a row for each group.
- **Order:** applies after `add-proxy-groups` is applied and accepted; its modified requirements replace that change's.
- **Toolchain:** none new.
