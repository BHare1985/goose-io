# Tasks

Ground rules for every task: work on a branch, not `main` (the branch `contract-v1` or one made from it). Do not push or tag without the owner's approval. Write the test before the code it tests and run it against the unchanged `memory.goose` to see it fail; a test that cannot fail on the old code proves nothing. A test that fails once in any repetition is a failure until its cause is explained. Add no provider API, no change to `goose_io.goose`, and no C, `extern` or build sidecar. A test of a loop that might not end must fail by its own counter or limit, never by hanging.

## 1. Baseline

- [x] 1.1 Run `tests/run_tests.sh` and `tests/check_docs.sh` on the branch and note the file count and result at the head of the first commit message; verify both pass before anything is changed, so every later failure is this change's

## 2. The loop always makes progress

- [x] 2.1 Write the tests first in `tests/unit/memory_time_test.goose`: `tick_ms` of 0 and of -5 with a handler that stops at 50 ms of loop time and fails the test itself if 10,000 events pass with the clock unmoved, at most one `Tick` per millisecond of that clock; `tick_ms` of -5 with no `stop`, `exit_on_time_limit` off, ending with `hit_time_limit()` true; `passes_per_ms` of 0 with two joined links exchanging bytes until a handler stops the loop; verify the tick tests fail on the current `memory.goose` (by the guard, not by hanging); the `passes_per_ms` case pins behaviour that already held and passes
- [x] 2.2 In `_start` raise `tick_ms` and `passes_per_ms` below 1 to 1; verify 2.1 passes and the rest of `tests/run_tests.sh` still passes
- [x] 2.3 Say in the comment on `Config` and in the configuration table of `docs/libraries.md` ("Testing a library") that `tick_ms` and `passes_per_ms` are raised to 1, and that no setting can stop a loop making progress; verify `tests/check_docs.sh` passes

## 3. Scripted peers finish reading before `serve` returns

- [x] 3.1 Write the tests first in `tests/unit/memory_peers_test.goose`, each stopping from a handler and not from a later `Tick`: send, `close`, `stop(0)` from the `Closed` handler, then `peer_received` equals the reply and `peer_saw_eof` is true; send, `shutdown_write`, `stop(0)` from the same handler, the same checks, and the link's `Closed` reason is `Shutdown`; a peer told to stop reading before the library sends and closes, so `serve` returns and `peer_received` holds only what was read before; a peer with a step due ten seconds later, so `serve` returns before it and the clock is below ten seconds; verify each of the first two fails on the current provider
- [x] 3.2 Add `_peer_read_work(io)` (an open scripted end that is not paused with unread bytes, or whose end of stream is unseen, or that will hang up after one) and use it both in the exit test of `serve` and in the busy test of `_advance` in place of the code duplicated there; verify 3.1 passes, that a run printing its event trace twice gives identical text, and that the whole suite passes
- [x] 3.3 Document in the scripted-peers section of `docs/libraries.md` that `stop` waits for a peer to read what it was sent but not for its timed steps or a peer that stopped reading, and what that means for reading `peer_received` after `serve`; verify the example given in the document is a test that passes under `tests/unit/`

## 4. A refused send is always resolved

- [x] 4.1 Write the tests first in `tests/unit/memory_data_test.goose` using a link buffer of 4096: (a) a `Writable` owed and queued, and a handler shuts the write side first: no `Writable`, `send` returns `Closed`, `Data` and `PeerEof` still arrive; (b) `shutdown_write` straight after a `Full`, the peer then reads everything: no `Writable`; (c) `Full`, `set_keep_open_on_eof(true)`, the peer closes without reading: exactly one `Writable` or the link's `Closed` and never neither, checked at the end of a loop that stops at 5,000 ms; (d) after that `Writable` the next `send` is `Sent` or `Closed`, never `Full`, and the link then ends; (e) a scripted peer blocked on `Full` whose library closes: the peer's step finishes and `peer_closed` is true; verify (a), (c) and (e) fail on the current provider
- [x] 4.2 Do not deliver a queued `Writable` in `_deliver` to a link with `wr_shut` (nothing new is queued after `shutdown_write`, which clears `want_writable`); verify (a) and (b) pass
- [x] 4.3 In `_queue_reads`, when a link that stays open (`keep_open`) sees its peer's end of stream, has `want_writable` and no peer left, queue the owed `Writable` after its `PeerEof`; verify (c), (d) and (e) pass, and that a link that is not `keep_open` still closes with `PeerClosed` and gets no `Writable`
- [x] 4.4 In `docs/contract.md` (section on `Writable`) state *A refused send is always resolved*, in the words of the requirement, and name it as the other requirements are named; verify `tests/check_docs.sh` passes and every requirement of `specs/io-contract/spec.md` in this change and in `define-contract-v1` is named in the document

## 5. Listeners and ports

- [x] 5.1 Write the tests first in `tests/unit/memory_links_test.goose`: wildcard then specific and specific then wildcard each fail the second `listen` with `AddressInUse`, and a dial reaches the first listener; `hold("0.0.0.0:8080")` blocks `127.0.0.1:8080`; different ports, the other family and a stopped listener do not conflict; `listen` on port zero after an explicit listen on `127.0.0.1:49152` succeeds with another port in 49152 to 65535; after 16,385 accepted connections port zero still gives a port at least 49152 and `peer_address` of the last accepted link is in range; with every port of the range on one address in use, port zero fails with `NoResources`; verify all but the last two fail on the current provider (the 16,385 connections run in one process in under ten seconds, otherwise lower the count with a documented reason)
- [x] 5.2 Add `_overlaps(a, b)` and use it in `listen` against `_held` and active listeners; keep `_same_endpoint` for `fail_dials` and `silent`; verify the overlap tests pass and `wildcard_listeners` in the same file still passes
- [x] 5.3 Replace the `_next_port` increments by one allocator that wraps inside 49152 to 65535; make `listen` on port zero try one lap of candidates, skip any that overlap, and fail with kind `NoResources` and code 99 after the lap; verify the port tests pass and the suite still passes
- [x] 5.4 In `docs/libraries.md` say that overlapping listeners are rejected with `AddressInUse` and how port zero is chosen; in `docs/contract.md` (Listening) say that whether overlapping listeners may coexist is a provider matter that a library does not depend on; verify `tests/check_docs.sh` passes

## 6. Stated limits

- [x] 6.1 Write the tests first in `tests/unit/memory_links_test.goose`: with `max_links` 2 one in-loop connection opens on both ends and a third dial fails with kind `NoResources`; with `max_links` 1 a dial to a scripted peer opens; `dial` and `listen` on `[::ffff:192.0.2.1]:80` give `ConnectFailed` of kind `BadAddress` and `BadAddress`; verify they pass on the current provider (they pin existing behaviour) and name each one after its scenario in `specs/provider-conformance/spec.md`
- [x] 6.2 Change the comment on `Config.max_links` and the row in `docs/libraries.md` to say it counts link ends on this loop, and state the address grammar in `docs/contract.md` (Addresses) and `docs/libraries.md`, including that IPv4-embedded IPv6 text is not accepted by this provider and a portable library does not use it; verify `tests/check_docs.sh` passes

## 7. Event ordering

- [x] 7.1 Write `tests/unit/memory_ordering_test.goose` with one function for each case of design D7 (a link closed while it has `Data`, `Writable` and `PeerEof` queued; a write side shut while a `Writable` is queued; a reset while the peer has `Data` queued; `stop(0)` with events queued for other links; operations inside a link's own `Closed` handler; the dialled end closed before its `Opened`; several events queued in one pass in order with `PassEnd` last and `Data` split by a small `read_chunk`); verify each passes on the fixed provider, and that the case for the write side shut fails on the provider as it was before task 4.2
- [x] 7.2 Run it fifty times (`for i in $(seq 50); do goose run tests/unit/memory_ordering_test.goose; done`) and with the events of one run printed twice; verify zero failures and identical output

## 8. Acceptance

- [x] 8.1 For each new test of groups 2 to 6, temporarily undo its fix in `memory.goose` and see the test fail, then restore it; verify `git diff` shows no leftover change and record the list of test names against fixes in the commit message
- [x] 8.2 Run `tests/run_tests.sh`, `tests/check_docs.sh` and `openspec validate harden-memory-provider --strict`; verify all three pass and that the file count is the baseline of 1.1 plus the new files

## Workflow follow-up

- In `define-contract-v1`, task 4.1's table counts scenarios with `grep -c "#### Scenario" specs/io-contract/spec.md`. Add this change's scenarios to it, and the checks for *A refused send is always resolved* to 4.3 to 4.7 (a part for `shutdown_write` with a `Writable` owed, a part for a `Full` whose peer closes), with each case of design D7 that holds on every provider. 4.8 needs a fault for each. This change does not edit that one.
- The `provider-conformance` requirements here describe the in-memory provider only; the suite must not check them on another provider.
- Apply this change before group 4 of `define-contract-v1`. The two can be archived in either order: this change adds requirements under new names and modifies none.
- Merge to `main`, push and tag only with the owner's approval.
- Archive this change after acceptance and verify the archived specifications.
