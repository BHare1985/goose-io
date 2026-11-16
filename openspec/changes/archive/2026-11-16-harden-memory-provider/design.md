# Design

## Context

`memory.goose` is the in-memory provider built in group 3 of `define-contract-v1` and is the only implementation the conformance suite (group 4) has been written against so far. An outside, static review of it (not compiled or run by the reviewer) made six groups of points. Every behavioural claim was reproduced with scratch programs kept outside the repository, against the commit the branch is on. The results decide what this change contains:

| # | Claim | Reproduced | Decision |
|---|---|---|---|
| 1 | `tick_ms` 0 hangs `serve` | Yes, and so does a negative value: 100,000 events at clock 0, the time limit never reached | Adopt. Clamp. Also clamp `passes_per_ms`. |
| 2 | Accepted bytes are lost to a scripted peer when the loop stops | Yes: `peer_received` empty, `peer_saw_eof` false after send, close, `stop(0)` | Adopt, with a narrower rule than the review's (D2). |
| 3A | `Writable` after `shutdown_write` | Yes, when a `Writable` is queued ahead of an event whose handler shuts the write side | Adopt. |
| 3B | `Full` left unresolved when the peer closes | Yes, with `keep_open`: `PeerEof`, then silence until the host's `stop` (`Closed` at 5001 ms) | Adopt, as an invariant in the contract and `Writable` in this provider (D4). |
| 4 | Overlapping listeners depend on order | Yes, both orders | Adopt: reject overlap (D5). Reject most-specific matching. |
| 4 | Ephemeral port retry | Yes: `listen(0)` fails after an explicit listen on 49152; the counter wraps to port 0 after 16,384 uses | Adopt (D5). |
| 5 | `max_links` counts link ends | Already true and already in a test comment | Document, pin with a test. |
| 5 | IPv4-embedded IPv6 text | `BadAddress` today | Do not implement. Document the grammar (D6). |
| 5 | Validate all configuration | Only `tick_ms` and `passes_per_ms` can stop the loop making progress; the others end in a failed dial or an early time limit | Narrower than the review: clamp those two only. |
| 5 | Generation wraparound | Matches the accepted 32-bit trade-off | No change. |
| - | Adversarial ordering tests after group 4 | Some exist (nesting depth, nothing after `close`, `close` inside `Closed`); the specific orderings of D7 do not | Adopt, but now, so group 4 starts from them. |

The review's verdict stands: keep the architecture (virtual clock, paired endpoints, scripted peers, inspection functions). The in-memory provider is a correctness reference for the contract's observable behaviour, not a Linux simulator, and this change adds no feature to it.

## Goals / Non-Goals

**Goals:**
- Each defect above has a test that fails on the current provider and passes after the fix.
- The two contract-level gaps (3A, 3B) become one stated requirement that a real provider must also meet, so group 4 can check it on any provider.
- The in-memory provider's observable behaviour is independent of call order wherever the contract is silent (listeners, ports).

**Non-Goals:**
- No new provider API and no change to `goose_io.goose`.
- No new fault switches: they belong to group 4.8, which will add one per check.
- No simulation of kernel behaviour that the contract does not state (dual-stack listeners, `SO_REUSEPORT`, TIME_WAIT, RST on close with unread input).

## Decisions

### D1. Normalise `tick_ms` and `passes_per_ms` in `_start`

`_start` already normalises `max_send`, `link_buffer` and `read_chunk`. It gains `tick_ms < 1` becomes 1 and `passes_per_ms < 1` becomes 1. The first is the hang. The second cannot hang (the clock then moves on every busy pass) but its meaning "passes before the clock moves" is only defined from 1. The other settings were checked one by one and none stops the loop making progress: `time_limit_ms` at or below 0 ends the run on the first pass, `connect_timeout_ms` at or below 0 times a silent dial out at once, `max_links` at or below 0 fails every dial with `NoResources`, `max_listeners` at or below 0 fails every `listen`.

Alternatives: reject with an exit (consistent with the time limit's behaviour but turns a harmless typo into a dead test); a general guard in `_advance` that moves the clock at least 1 ms on an idle pass (hides the mistake and gives the same result as the clamp).

### D2. `serve` waits for scripted peers to read what they were sent

The exit test in `serve` is `draining && no library links && nothing queued`. It gains `&& no scripted peer has work to read`. That work is exactly what `_advance` already treats as busy for an open scripted end: unread bytes while not paused, or an end of stream not yet seen, plus the hang-up that follows an end of stream when the peer has no steps left. It is one predicate, `_peer_read_work`, used by both places, so the two cannot drift.

Deliberately not included: the peer's remaining timed steps, and a peer that is paused. A loop that waited for every step would make `stop` mean "run the whole script", and a test that wants a peer that never reads must still be able to end. The review asked for the same limit ("You don't need to wait for a peer explicitly told to stop reading").

The existing tests did not find this because they stop on a later `Tick` (`stop_after(io, ev, 300)`), by which time the peer had read. The new tests stop from the `Closed` handler, which is what a real test does.

Cost: one or two extra passes after `stop`, with no library link left, so no link event reaches a handler. A `Tick` may be delivered if one is due.

### D3. A link whose write side is shut gets no `Writable`

`_deliver` does not deliver a queued `Writable` to a link with `wr_shut`. One place is enough: `shutdown_write` already clears `want_writable`, so nothing new is queued after it, and the only `Writable` that can still arrive is one queued before the call, which the delivery check drops. `close` and `reset` already end the link's events (state `_CLOSED`). The scripted peer's own `blocked` flag is released by its `Writable` as before; a peer that has shut its write side has no send step left to block.

### D4. A refused send is always resolved

Contract level: *A refused send is always resolved* states the invariant (`Writable` or `Closed`, never silence, never `Writable` after the write side is shut). It leaves the choice for a vanished peer to the provider because a socket-backed provider will normally see the reset and close the link with `PeerReset`, while the in-memory model already says "the other end is gone: the bytes are accepted and lost and the link is reset".

In-memory provider: when a link sees its peer's end of stream, stays open (`keep_open`), has `want_writable` and no peer left (`peer < 0`, which excludes a peer that only shut its write side and still reads), `_queue_reads` queues the owed `Writable` after the `PeerEof`. The retry then returns `Sent` and resets the link, exactly as a send to a vanished peer does today. A link that is not `keep_open` closes with `PeerClosed` at the same point, and `_mark_closed` already clears its `want_writable`.

Alternative: close the surviving link with `PeerReset` at once. Rejected for this provider: it would make `keep_open` mean "closes anyway" whenever a send had been refused, and it contradicts the existing rule that a graceful close by the peer is an end of stream and not a reset. Resolving where the end of stream is seen keeps the rule that the library hears about the end through `PeerEof` first.

Also resolves, for a scripted peer, the case in which the library closes while the peer has a send blocked on `Full`: its `Writable` frees `blocked`, and the step then finishes against a link that has ended.

### D5. Listener overlap and ephemeral ports

`_overlaps(a, b)`: same family, same port, and either is the wildcard or the addresses are equal. `listen` uses it against held addresses and active listeners instead of `_same_endpoint`. `_listener_takes` is unchanged, so a dial now meets at most one listener and the order of registration no longer matters. A stopped listener is not active and does not conflict, as before. `fail_dials` and `silent` keep exact matching: they describe dial targets, not bindings.

Rejecting overlap is what Linux does for two listening sockets without `SO_REUSEPORT`, and it needs no rule about precedence. IPv4 and IPv6 stay separate families here (Linux's dual-stack `[::]` would also take IPv4); the contract does not mention dual-stack, so the provider does not model it, and *Listener addresses do not overlap* says so.

Ports: one allocator for the range 49152 to 65535 that wraps inside the range. `listen` on port zero tries candidates in order, skipping any port that would overlap, and fails with `NoResources` (code 99) after one full lap. Accepted links take their remote port from the same counter, so it never leaves the range either. Remote ports are informational and are not checked for collisions.

Alternative: most-specific-match. Rejected: it needs a precedence rule for every combination, and no real provider offers it.

### D6. What is documented and not implemented

`max_links` counts link ends on the loop. It is already so; the comment in `memory.goose` and the table in `docs/libraries.md` say "links" and one test comment explains it. They now say what is counted and a test pins it. The address grammar is stated in `docs/contract.md` as the portable one: `ip:port` and `[hex-groups]:port`. A provider may accept more (`inet_pton` accepts `::ffff:192.0.2.1`), and a portable library does not pass such text. Supporting the dotted tail in the in-memory provider would need an output rule too (what `peer_address` writes for a mapped address), which is a contract decision, and no library needs it yet. It is recorded as unsupported, not as a gap in the contract.

`docs/contract.md` also gets one sentence under Listening: whether two listeners on overlapping addresses may coexist is a provider matter, and a library does not depend on it.

### D7. Adversarial ordering tests

`tests/unit/memory_ordering_test.goose`, written first, each case a specific order inside one pass:

1. A handler for link A's event closes link B while B has a `Data`, `Writable` and `PeerEof` queued: B gets only its `Closed`.
2. A handler shuts B's write side while a `Writable` is queued for B (3A).
3. A handler resets B while B's peer has queued `Data`.
4. A handler calls `stop(0)` with events still queued for other links: all are delivered before `serve` returns, each link once and `Closed` last.
5. Operations on a link, including a second `close` and a `send`, from inside its own `Closed` handler: no effect, no further event.
6. The handler of the accepted end's `Opened` closes the dialled end before that end's own `Opened` is delivered: the dialled end gets no `Opened` and one `Closed`, and the accepted end sees a clean end.
7. Several events queued in one pass arrive in the order they were queued, `PassEnd` last, and with `cfg.read_chunk` small enough that one link's `Data` is split, its pieces are in order.

Whatever of these holds for any provider is a candidate check for group 4. Each is recorded there as a scenario by name, not copied.

## Risks / Trade-offs

- [The settle in D2 adds passes after `stop`, so a test that counts `passes()` after a stop sees a larger number] → The tests that read `passes()` do not stop on the last event; the full suite is run before and after to find any that do.
- [Overlap rejection rejects a pair that a user wrote on purpose] → None in the repository (the tests use the wildcard on separate ports). The documents say it, and `AddressInUse` names the problem.
- [Delivering `Writable` after `PeerEof` could surprise a library that ignores `Writable` for a link it considers finished] → The contract already requires a library to tolerate `Writable` on an open link; the retry gives `Sent` or `Closed`, never `Full` (scenario *The retry after the peer is gone*).
- [New scenarios in `io-contract` that `define-contract-v1`'s table in task 4.1 does not list] → Apply this change before group 4; `tasks.md` records what to add to 4.1 and 4.3 to 4.7.
- [The review was static; behaviour it described could differ from the code] → All claims that this change acts on were reproduced first. Claims it made that were already true (`max_links`, the generation trade-off) are recorded as such.

## Migration Plan

Code changes are confined to `memory.goose`. Tests and documents change with the code in each group of `tasks.md`. No other repository is affected. Rollback is reverting the branch.
