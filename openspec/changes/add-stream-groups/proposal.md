## Why

The contract moves bytes only through `Data` and `send`, so every byte of a stream passes through a library's memory. That cannot express what a TCP proxy, a static-file server or a multi-threaded server needs, and it shuts out kernel mechanisms (`splice`, `sendfile`, zero-copy send, `MSG_PEEK`, cross-thread wake) that an epoll or io_uring loop could use. tcprouter, the first real proxy to move onto goose-io, needs four of them and must lose no feature in the move; the others close the same kind of gap for other stream programs. The contract already has a way to add capabilities that only some loops supply: optional groups. This change defines the groups, so a loop can offer a kernel shortcut under a stated, tested meaning and a library says in its header that it needs it.

## What Changes

- Add eight optional groups to the contract; the core and the six existing groups are unchanged:
  - **relay**: `relay(a, b)` joins two links so the loop moves the bytes between them, in both directions, with backpressure and half-close carried through and no `Data` for either link; `relayed_bytes(link)`.
  - **peek**: `peek(link)` shows the bytes that have arrived and not yet been given as `Data`, `wait_input(link, n)` holds `Data` back until `n` bytes (or the peer's end) have arrived, and the event `Input` says so. The bytes stay for `Data` afterwards.
  - **revoke**: `discard_unsent(link)` takes back bytes the loop has not yet handed to the transport, and `write_deadline(link, at_ms)` makes the loop write nothing after a time, checked at the moment of each write.
  - **wake**: `waker()` and `wake(waker, value)`, callable from any thread, and the event `Woken` delivered on the loop's thread.
  - **files**: an opaque `File`, `open_file`, `close_file` and `send_file(link, file, offset, len)`.
  - **loans**: `loan(size)`, `loan_bytes`, `send_loan(link, loan, len)` and `release_loan`: a send from a buffer the loop lent, so the loop may send it without copying.
  - **parts**: `send_parts(link, parts)`, `send2` for any number of parts.
  - **addresses**: `local_address(link)` and `original_destination(link)`.
- Add the compile-time check of each group that has operations (`require_relay`, `require_peek`, `require_revoke`, `require_wake`, `require_files`, `require_loans`, `require_parts`, `require_addresses`), and the two new events `Input` and `Woken` to `Event`.
- **BREAKING (compile time only):** a `match` on `Event` with no `_` arm must name `Input` and `Woken`, as it already had to name `PassEnd`. No behaviour of a loop that does not supply the groups changes.
- Add a conformance entry point for each group, an implementation of each group in the in-memory loop, and a fault for every check, as the contract requires of every group.
- Implement the groups on the epoll loop of `goose-io-epoll-ext` (relay by the pump of tcprouter's engine, peek by `MSG_PEEK`, revoke by its send queue and the clock, wake by an `eventfd`, files by `sendfile`, loans and parts by the loop's own buffers, addresses by `getsockname` and `SO_ORIGINAL_DST`), in the order the tasks give.
- Audit tcprouter's behaviours (its `RT-n` rows) against the contract with these groups, row by row, before any port claims parity; a row with no operation to carry it becomes a change to a group here, not a dropped feature.

Out of scope: handing a link to another thread or process, datagrams (UDP, QUIC), TLS and kernel TLS, and porting tcprouter itself (a separate project gated by the audit). Per-socket tuning (nodelay, reuseport, defer-accept, busy-poll, buffer sizes) stays configuration of the loop, set by the application when it constructs it, and is not contract.

## Capabilities

### New Capabilities

None. The groups extend the contract and the suite that already exist.

### Modified Capabilities

- `io-contract`: the contract gains eight groups and two events; the requirement that names the groups and the one that checks them change, and each group has requirements of its own.
- `provider-conformance`: the suite gains an entry point and checks for each group, and the in-memory loop supplies each group and a fault for each check.

## Impact

- **goose-io code:** `goose_io.goose` (types, events, `require_*` checks), `memory.goose` (the groups and faults), `conformance/` (checks), `tests/conformance/` (table, group check, runner), `docs/contract.md`, `docs/libraries.md`, `docs/event-loops.md`. The pure-Goose rule is kept: no C in the package.
- **Libraries:** none changes; an exhaustive `match` on `Event` gains two arms (the example libraries already end in `_ =>` or `PassEnd`).
- **Event loops:** the epoll loop of `goose-io-epoll-ext` (`~/dev/goose-io/.implementations/`) implements the groups; `goose-io-epoll` stays the plain loop and `examples/README.md` links both.
- **tcprouter:** nothing changes here; the audit and the port come after, in the tcprouter clone.
- **Toolchain:** Goose v2026.4, Linux for the epoll loop; no new dependencies.
