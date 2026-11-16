# Proposal

## Why

The in-memory provider (`memory.goose`) is the one working implementation of the contract, and the conformance suite (group 4 of `define-contract-v1`) will be written to agree with it. An outside static review of it found problems; each was reproduced against the current code with scratch programs before this change was written. Fixing them before the suite exists is cheap. Fixing them after means the suite's expectations have to be unpicked.

Reproduced:

- `cfg.tick_ms` of 0 or less makes `serve` run for ever. The next tick is always due, the clock never moves, so the virtual-time limit that exists to stop a runaway test never fires (100,000 events at clock 0 in the repro).
- `send`, then `close`, then `stop(0)` from the `Closed` handler, returns from `serve` before a scripted peer has read anything: `peer_received` is empty and `peer_saw_eof` is false. The contract says `stop` counts a closing link as present until its bytes are out; the provider does not apply that to a scripted peer, so the natural test of "close does not lose accepted bytes" reads nothing.
- A `Writable` that was queued before the library called `shutdown_write` is still delivered afterwards, although nothing can ever fit again.
- A link that was refused with `Full`, has `set_keep_open_on_eof(true)`, and whose peer then closes, gets `PeerEof` and nothing else: no `Writable`, no `Closed`. It stays open, waiting, until the host stops the loop (`Closed` at 5001 ms in the repro).
- Listening on `0.0.0.0:8080` and then `127.0.0.1:8080` both succeed, and a dial goes to whichever was registered first. The reverse order gives the same result. The outcome depends on call order, and Linux would refuse the second listen.
- `listen` on port 0 fails with `AddressInUse` if the next ephemeral port was explicitly listened on. The counter is also spent by every accepted connection and is cast to `u16`, so after 16,384 allocations it yields port 0 and then low ports.

What the review got right is its verdict: keep the architecture. This change is fixes and documentation of existing limits. It adds no new provider API.

## What Changes

- Normalise `cfg.tick_ms` (at least 1) and `cfg.passes_per_ms` (at least 1) in `_start`, with tests for zero and negative values. Other configuration values were checked: none can make the loop stop progressing, so none is rejected.
- `serve` does not return, after `stop`, while a scripted peer has accepted bytes it has not read or an end of stream it has not seen. A peer that was told to stop reading, or whose later steps are not yet due, does not hold the loop.
- Suppress `Writable` for a link whose write side has been shut, including one already queued.
- Resolve an outstanding `Full` when the other end goes away: the in-memory provider delivers the owed `Writable`; the next send is then accepted and lost and the link is reset, as it already is.
- A new contract requirement states the invariant behind the last two: **a `Full` is always resolved**, by one `Writable` or by the link's `Closed`, never by silence, and never by a `Writable` on a link that can no longer send. Which of the two a provider gives is left to it, because a kernel-backed provider will usually report the reset.
- In the in-memory provider, a `listen` that overlaps a listener or a held address (same family and port, and either address is the wildcard or both are equal) fails with `AddressInUse`. Dials then match at most one listener. Port 0 picks a free port from 49152 to 65535, skips ports in use, wraps inside that range, and fails with `NoResources` only when the range is full.
- Document, without changing behaviour: `max_links` counts link ends on this loop, not connections, so a joined pair uses two; the accepted address grammar is `ip:port` and `[hex groups]:port`, and IPv4-embedded IPv6 text such as `::ffff:192.0.2.1` is `BadAddress` on the in-memory provider and must not be relied on by a portable library.
- Add `tests/unit/memory_ordering_test.goose`: adversarial event ordering (operations inside handlers, several events queued in one pass, a link closed or write-shut by an earlier event of the same pass), written now rather than after the suite so that the conformance checks of group 4 can be taken from it.

Out of scope: any new provider feature, support for IPv4-embedded IPv6 text, most-specific listener matching, dual-stack listener rules, a simulation of Linux networking beyond the observable contract, and the conformance suite itself (this change only supplies it with scenarios and tests to carry over).

## Capabilities

### New Capabilities
- `io-contract`: one added requirement, *A refused send is always resolved*. The capability is created by `define-contract-v1` and is not yet in `openspec/specs/`; the requirement is added under a new name, so the two changes can be archived in either order.
- `provider-conformance`: added requirements for the in-memory provider: *The in-memory loop always makes progress*, *Stopping lets scripted peers finish reading* and *Listener addresses do not overlap*. Same capability path as `define-contract-v1`, new requirement names.

### Modified Capabilities

None. No specifications have been archived in this repository.

## Impact

- **Code:** `memory.goose` only. No change to `goose_io.goose`, so no provider that implements the contract has anything to change.
- **Tests:** new cases in `tests/unit/memory_time_test.goose`, `memory_close_test.goose`, `memory_data_test.goose`, `memory_links_test.goose` and `memory_peers_test.goose`, and a new `memory_ordering_test.goose`. Each is written first and shown to fail on the current provider.
- **Documents:** `docs/contract.md` (the Full invariant, the address grammar, overlap), `docs/libraries.md` ("Testing a library": `max_links`, `tick_ms`, listening, scripted peers and `stop`).
- **Other changes:** `define-contract-v1` groups 4.1 and 4.3 to 4.7 should count the new scenarios. This change does not edit that change; the follow-up is recorded in `tasks.md`. Apply this change before group 4 starts.
- **Compatibility:** only a test that depended on a scripted peer reading nothing after `stop` could change; none is known, and the tasks run the whole suite before and after to find out.
