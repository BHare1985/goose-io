# Writing a provider and running the conformance suite

A provider is the part of a program that owns a thread's event loop and supplies the operations and events of
the contract (`docs/contract.md`). This document is for the author of one. It lists what the conformance suite
checks and where each requirement of the contract is proved; what a provider must supply, how to run the suite on
it, the fixture, how to read a failure and the rule for being listed as conforming come first, and the table that
says where each requirement is proved follows.

## What a provider must supply

The operations and events of `docs/contract.md`, with the types of `goose_io.goose`, as functions that a
library calls by method syntax on the provider's loop type: `listen`, `listener_port`, `stop_listening`, `dial`,
`peer_address`, `send`, `send2`, `send_room`, `max_send`, `pause_reading`, `set_keep_open_on_eof`,
`shutdown_write`, `close`, `reset`, `set_user`, `user`, `now_ms`, `tick_by`, `serve`, `stop` and `draining`.

Call `goose_io::require_provider(io)` once from the provider's root program. It names every operation with the
contract's argument and result types and never runs, so a missing or mistyped operation is a compile error at
that one line, and not deep inside a library. A provider with nothing more than these operations conforms;
anything it adds (name resolution, TLS, other transports) is not part of the contract and no library may need
it (*Scope of the base contract*).

## Running the suite

The suite is the directory `conformance/` (import `goose_io.conformance.suite`; the namespace is `goose_io_conformance`): `suite.goose` is the driver and entry point, `support.goose` holds what every check shares, and `handles`, `net`, `data`, `close` and `time` hold the checks. It
imports the contract and nothing that names a provider. Both ends of every link are on the provider under test:
a check listens on the loopback with port 0 and dials the port it was given, and makes the peer's behaviour with
contract calls (`reset`, `shutdown_write`, `pause_reading`, not sending). It therefore runs unchanged on any
provider, over IPv4 and IPv6 loopback.

A provider's root program constructs its loop, builds a fixture and calls the entry point of the core and of each group it supplies (`conformance_core_part`, `conformance_half_close_part`, `conformance_sizing_part`, `conformance_abort_part`, `conformance_inspection_part`, `conformance_batching_part`) with a part number.
This is the program that runs the in-memory provider, whose suite results the tests of this repository rely on:

<!-- source: tests/conformance/memory_conformance.goose -->
```goose
// Runs one part of the conformance suite against the in-memory provider: `goose run tests/conformance/memory_conformance.goose -- 3 core`.
// The part is the first argument (default 0) and the group the second (core, half-close, sizing, abort, inspection or batching; default core).
// The environment variable GOOSE_IO_FAULT, when set, switches the in-memory provider to one of its named faults
// (see tests/conformance/faults.sh).
import std;
import os;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;

fn main() {
    var part = 0;
    if arg_count() > 1 {
        var text: u8[>..] = [];
        arg(1, text);
        part = 0;
        for c in text { if c >= '0' && c <= '9' { part = part * 10 + (c - '0'); } }
    }
    var group: u8[>..] = [];
    if arg_count() > 2 { arg(2, group); }
    var io = goose_io_memory::Loop { .. };
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
    io.silent("10.255.0.1:81");
    io.hold("127.0.0.1:9999");
    let up = io.add_peer();
    io.peer_accept(up, "10.255.0.2:80");
    let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9", answers: "10.255.0.2:80" };
    if group == "half-close" { exit(goose_io_conformance::conformance_half_close_part(io, fixture, part)); }
    if group == "sizing" { exit(goose_io_conformance::conformance_sizing_part(io, fixture, part)); }
    if group == "abort" { exit(goose_io_conformance::conformance_abort_part(io, fixture, part)); }
    if group == "inspection" { exit(goose_io_conformance::conformance_inspection_part(io, fixture, part)); }
    if group == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_core_part(io, fixture, part));
}
```

Only one `stop` can be observed in one `serve`, so the suite is divided into **parts** and each part is run in
its own process. Part 0 is every check that does not need `stop`, ending with *stop with nothing open*. Parts 1
to 5 are one scenario of `stop` each: a link that stays open, libraries that finish, listening while draining,
dialling while draining, and `stop` called twice. The core has parts 0 to 5; every group has part 0 only. The root program
above takes the part as its first argument and the group as its second; `tests/conformance/run.sh` runs all of them:

```
tests/conformance/run.sh                 # every part of every group once
tests/conformance/run.sh --group sizing  # one group only
tests/conformance/run.sh --repeat 50     # fifty times: any failure in any repetition fails the run
```

Each entry point returns the number of checks that failed, so `exit(...)` of it is the program's status. Time
bounds in the checks use the loop's clock (`now_ms`), so the same bounds hold on a virtual clock and on a real one.
A check that has to wait for a provider limit it cannot know (*A peer that never reads*) allows two minutes of that
clock.

### The fixture

A fixture supplies the two things that contract calls cannot produce:

| Field | What the runner supplies |
|---|---|
| `silent` | An address to which a connect is never answered, so a dial to it ends only when its connect time passes. In the in-memory provider, `io.silent(address)`; on a socket provider, an address that drops packets. |
| `held` | An address on which `listen` fails with `AddressInUse`. In the in-memory provider, `io.hold(address)`; on a socket provider, a port another socket already holds exclusively. |
| `refused` | An address that nothing listens on, so a dial to it is refused. In the in-memory event loop any address no one listens on; on a socket loop, a port that no socket holds. |
| `answers` (optional) | An address that still accepts connections while the loop is draining. See `dial_while_draining` below. |

### Reading a failure

Each check prints `ok   <name>` or `FAIL <name> [<requirement>]: <what was wrong>`. The requirement is the name of
the requirement in `specs/io-contract/spec.md` and in `docs/contract.md` (each requirement is named there, in
italics). The last line gives the number of checks run and failed. A failed check stops that check only, so one
output shows every failing requirement of the part. A check that did not finish by its deadline on the loop's
clock fails with *not finished in time*; one whose events arrive from inside another handler fails with *an event
was delivered from inside the handler of another event*.

A check that fails in any repetition is a failure until its cause has been explained: `run.sh --repeat` does not
average. On the in-memory provider the output of every repetition is also compared with the first.

### The suite tests itself

`tests/conformance/faults.sh` switches the in-memory provider to one named fault after another (a deliberate break
of one behaviour, listed in `tests/conformance/checks.tsv`) and requires the check for that behaviour to fail. A
check that passes against its own fault is a defect in the suite. `tests/conformance/table_check.sh` requires the
table below to name every scenario of the specification and every check of the suite.

## Being listed as conforming

A provider is described as conforming only after the whole suite (every part) has passed against it on the
operating system it targets, and its documentation says which contract version (`goose_io::VERSION_MAJOR` and
`VERSION_MINOR`) and which commit of the provider that was. A provider that fails any check is not listed.
While the contract is at major version 0 a provider may find that a requirement cannot be met on its backend; it
then records what it tried, and the contract is changed only if no other way works (design D13 of the change that
introduced it).

## Layering one provider over another

A provider may wrap another and present the same contract above it (*Providers can be layered*): a TLS layer,
a compression layer, a metering layer. `tests/support/wrapper.goose` is a small one and shows the pattern. Over
the in-memory provider it

- changes every byte on the way out (XOR with a key) and restores it on the way in, so the links of the wrapper
  see their own bytes while the provider underneath carries something else;
- delays each link's `Opened` by one pass, holding back in order whatever the link gets meanwhile; and
- passes every other event, and every other operation, through unchanged.

`tests/conformance/run.sh --wrapped` runs every part of the suite against it, and `tests/examples/over_wrapper.sh`
runs the tests of the example libraries over it, with no change to the suite, to the provider underneath, or to
either library. What the wrapper had to get right is what any layer has to:

- **Events are queued, never nested.** The wrapper decides what the host is to be given while it handles an event
  of the provider beneath, and the `serve` block gives it, one at a time, after the handler of the event beneath
  has returned. An operation of the wrapper never calls the host.
- **A delayed `Opened` delays what follows it.** A link's `Data`, `Writable`, `PeerEof` and `Closed` wait, in
  order, behind its `Opened`. A link closed before its `Opened` was given gets only its `Closed`.
- **Choices made at `Opened` must be kept until `Opened` is given.** A library chooses what the peer's end of
  stream does (`set_keep_open_on_eof`) while it handles `Opened`. If `Opened` is delayed, the provider beneath
  would act on its default first. The wrapper keeps every link beneath open on end of stream, remembers what the
  library chose, and when the end of stream comes closes the link with `PeerClosed` itself unless the library asked
  to keep it open. It reads the choice when it gives the event and not before, because the library makes it while
  handling one of the events given just before.
- **`PassEnd` is the wrapper's own.** It is given once after the pass's link events, and before the next `Tick`,
  also for a pass in which only events the wrapper released were given.
- **A scripted peer on the provider beneath sees what is on the wire**, so a test that uses one goes through the
  wrapper's `peer_` functions, which change the bytes the other way.

## Which check proves which scenario

Every scenario of `specs/io-contract/spec.md` of the change `define-contract-v1` is in this table. A scenario
that describes provider behaviour has at least one check in `conformance/`, named in the third column. A
scenario that no provider call can show (that the package builds, that it pulls in nothing native, that a
library imports no provider) names the build or inspection step that proves it. The last column is the fault of
the in-memory provider (`set_fault`, in `memory.goose`) that makes the check fail: a check that passes while its
fault is on is a defect in the suite, and `tests/conformance/faults.sh` finds it.

The same rows, with the scenario texts, are in `tests/conformance/checks.tsv`; `tests/conformance/table_check.sh`
fails when this table, that file, the suite and the specification disagree.

<!-- scenarios:begin -->
| Requirement | Scenario | Proved by | Part | Fault that must make it fail |
|---|---|---|---|---|
| The contract package is pure Goose | The package checks cleanly | build: `goose check goose_io.goose` (`just check`) | - | - |
| The contract package is pure Goose | Nothing native is pulled in | inspection: the search commands of `tests/checks/purity.sh`, run by `tests/run_tests.sh` (task 7.2) | - | - |
| Three roles, one contract | A library compiles against two providers unchanged | build: `tests/unit/library_example_test.goose` on the in-memory provider and over the wrapper of `tests/support/wrapper.goose` (`tests/examples/over_wrapper.sh` runs the example library tests over it) | - | - |
| Three roles, one contract | A library imports no provider | inspection: `tests/examples/imports_test.sh` lists the imports of `examples/`  | - | - |
| The contract exposes no operating-system primitives | A zone identifier is rejected | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| The contract exposes no operating-system primitives | A provider without descriptors conforms | inspection: the in-memory provider has no descriptors and passes `tests/conformance/run.sh` | - | - |
| The contract states its version | A library reads the version | build: `tests/unit/types_test.goose` reads `VERSION_MAJOR` and `VERSION_MINOR` | - | - |
| Links are generation-checked handles | A stale handle cannot reach a reused slot | check `handles_stale_reuse`, `handles_stale_reset`, `handles_stale_send_room`, `handles_stale_user` | 0 | `StaleHandleAccepted`, `StaleHandleAccepted`, `StaleHandleAccepted`, `StaleHandleAccepted` |
| Links are generation-checked handles | The handle is still valid while Closed is handled | check `handles_valid_in_closed` | 0 | `ClosedHandleStaleEarly` |
| Links are generation-checked handles | An unset handle is recognisably invalid | check `handles_unset`, `handles_unset_reset`, `handles_unset_shutdown_write`, `handles_unset_sizing`, `handles_unset_inspection` | 0 | `UnsetHandleAccepted`, `UnsetHandleAccepted`, `UnsetHandleAccepted`, `UnsetLinkHasRoom`, `UnsetHandleAccepted` |
| Events are delivered to one handler, one at a time | A close does not re-enter the handler | check `events_not_reentrant` | 0 | none (see below) |
| Events are delivered to one handler, one at a time | A send that closes the link does not re-enter the handler | check `events_not_reentrant_after_reset` | 0 | none (see below) |
| Link events follow a fixed order | An accepted link | check `order_accepted_link` | 0 | `PeerCloseDropsData` |
| Link events follow a fixed order | A link that never opens | check `order_failed_dial` | 0 | `OpenedBeforeFailure` |
| Every link event names its owner | Two libraries share one loop | check `owner_tags` | 0 | `WrongTag` |
| Every link event names its owner | The user value comes back | check `owner_user_value` | 0 | `UserLostInData` |
| Every link event names its owner | The user value survives an immediate dial failure | check `owner_user_after_failed_dial` | 0 | `UserReadAtDial` |
| Listening | A connection is accepted | check `listen_accepts` | 0 | `OpenedWithoutListener` |
| Listening | The address is taken | check `listen_held_address` | 0 | `HeldIgnored` |
| Listening | A system-chosen port can be discovered | check `listen_port_zero` | 0 | `PortZeroReportsZero` |
| Listening | Stopping a listener keeps its links | check `listen_stop_keeps_links` | 0 | `StopListeningClosesLinks` |
| Listener handles are never reused | A stale listener handle cannot reach a newer listener | check `listener_handle_never_reused` | 0 | `ListenerHandleReused` |
| Listener handles are never reused | Handles run out and do not wrap | unit test: `tests/unit/memory_links_test.goose` (`listener_exhaustion`); for a socket provider, its mapping document (group 6) | - | - |
| A link reports its peer's address | An accepted link names its peer | check `peer_address_names_peer` | 0 | `StalePeerAddress` |
| A link reports its peer's address | A dialled link names its target | check `peer_address_names_peer`, `peer_address_ipv6` | 0 | `StalePeerAddress`, `Ipv6Unsupported` |
| A link reports its peer's address | A closed link has no peer address | check `peer_address_names_peer` | 0 | `StalePeerAddress` |
| Dialling never blocks and always ends in one event | A successful dial | check `dial_succeeds` | 0 | `DialReturnsInvalid` |
| Dialling never blocks and always ends in one event | A refused dial | check `dial_refused` | 0 | `RefusedAsUnreachable` |
| Dialling never blocks and always ends in one event | A dial that times out | check `dial_times_out` | 0 | `TimeoutEarly` |
| Dialling never blocks and always ends in one event | A host name is rejected, not resolved | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| A failed dial says why | A malformed address or a host name | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| A failed dial says why | A dial that times out says so | check `dial_times_out` | 0 | `TimeoutEarly` |
| A failed dial says why | A refused dial | check `dial_refused` | 0 | `RefusedAsUnreachable` |
| A failed dial says why | A provider out of links | unit test: `tests/unit/memory_links_test.goose` (`link_limit`); for a socket provider, its mapping document (group 6) | - | - |
| A failed dial says why | A library handles every kind | test: `tests/examples/lineclient_test.goose` (task 5.3) | - | - |
| Received bytes are lent for the duration of the event | Bytes arrive as a slice | check `data_arrives_as_slices` | 0 | `DataCorrupted` |
| Received bytes are lent for the duration of the event | A slow handler holds one buffer | check `data_slice_stable_in_handler` | 0 | `SendClobbersLentBytes` |
| Sending is all or nothing | The caller reuses its memory at once | check `send_copies_at_once` | 0 | `SendDropsLastByte` |
| Sending is all or nothing | A small send is accepted | check `send_copies_at_once` | 0 | `SendDropsLastByte` |
| Sending is all or nothing | A send before the link opens | check `send_before_open`, `send2_refusals` | 0 | `SendBeforeOpenSent`, `SendBeforeOpenSent` |
| Sending is all or nothing | A send after close | check `send_after_close`, `send2_refusals` | 0 | `SendAfterCloseAccepted`, `SendBeforeOpenSent` |
| Two parts can be sent as one | A header and a body | check `send2_joins_parts` | 0 | `Send2SwapsParts` |
| Two parts can be sent as one | Neither part is taken when both do not fit | check `send2_all_or_nothing` | 0 | `Send2TakesFirstPart` |
| Send backpressure is explicit and bounded | An oversized send never fits | check `send2_refusals`, `send_too_large` | 0 | `SendBeforeOpenSent`, `TooLargeGivesWritable` |
| Send backpressure is explicit and bounded | A reader that never reads does not grow memory | check `send_is_bounded` | 0 | `NeverFull` |
| Send backpressure is explicit and bounded | No room on a link that cannot send | check `send_room_is_zero_when_closed` | 0 | `RoomWhenClosed` |
| Writable follows Full once | A full queue is reported and later reopened | check `writable_after_full` | 0 | `NoWritable` |
| Writable follows Full once | Several refusals share one Writable | check `writable_once_for_many_refusals` | 0 | `WritablePerRefusal` |
| Writable follows Full once | Writable means the refused send fits | check `writable_means_it_fits` | 0 | `WritableOnFirstByte` |
| Writable follows Full once | A later refusal gets its own Writable | check `writable_next_episode` | 0 | `OneWritableOnly` |
| Reading can be paused | Pause and resume | check `pause_and_resume_reading` | 0 | `PauseIgnored` |
| Closing | Close after a reply | check `close_after_reply` | 0 | `PeerCloseDropsData` |
| Closing | Nothing but Closed after close | check `close_leaves_only_closed` | 0 | `WritableAfterClose` |
| Closing | Cancelling a dial | check `close_cancels_a_dial` | 0 | `CancelledDialOpens` |
| Closing | Reset | check `reset_aborts_the_peer` | 0 | `ResetIsGraceful` |
| Close does not lose accepted bytes | Close with unread input | check `close_with_unread_input` | 0 | `CloseWithUnreadResets` |
| Close does not lose accepted bytes | A peer that never reads | check `close_when_peer_never_reads` | 0 | `ClosedNeverDelivered` |
| Peer end of stream and half-close | Default behaviour on peer end of stream | check `peer_eof_closes_by_default` | 0 | `EofIgnoresDefault` |
| Peer end of stream and half-close | Answering after the peer half-closes | check `half_close_then_answer`, `shutdown_write_ends_sending` | 0 | `PeerEofBeforeData`, `SendAfterShutdownAccepted` |
| Close reasons are portable | The peer resets the connection | check `reset_aborts_the_peer` | 0 | `ResetIsGraceful` |
| Close reasons are portable | A provider-specific reason reaches a portable library | unit test: `tests/unit/memory_close_test.goose` (`close_with_reason`) and `tests/examples/lineclient_test.goose` (task 5.3) | - | - |
| Time and ticks | Regular ticks | check `ticks_are_regular` | 0 | `TickEvery250` |
| Time and ticks | A deadline shorter than the tick period | check `tick_by_is_prompt` | 0 | `TickByIgnored` |
| Time and ticks | Two libraries with different deadlines | check `tick_by_two_deadlines` | 0 | `TickByKeepsLatest` |
| End-of-pass notification | Batching replies | check `pass_end_follows_link_events` | 0 | `NoPassEnd` |
| End-of-pass notification | PassEnd is last | check `pass_end_follows_link_events` | 0 | `NoPassEnd` |
| End-of-pass notification | An idle pass | check `pass_end_not_on_idle_pass` | 0 | `IdlePassEnd` |
| The host runs and stops the loop | Stop with nothing open | check `stop_with_nothing_open` | 0 | `StopWaitsForGrace` |
| The host runs and stops the loop | Stop with a link that stays open | check `stop_link_stays_open` | 1 | `ShutdownEarly` |
| The host runs and stops the loop | Libraries finish and the loop ends early | check `stop_libraries_finish` | 2 | `StopWaitsForGrace` |
| Draining is the same on every provider | Listening while draining | check `listen_while_draining` | 3 | `ListenAfterStop` |
| Draining is the same on every provider | Dialling while draining | check `dial_while_draining` | 4 | `DialFailsWhileDraining` |
| Draining is the same on every provider | Stop called twice | check `stop_called_twice` | 5 | `StopLatestWins` |
| Providers can be layered | A transforming wrapper conforms | conformance: every part through the wrapper of `tests/support/wrapper.goose` (`tests/conformance/run.sh --wrapped`) | - | - |
| Providers can be layered | A library cannot tell | test: the example library tests over the wrapper (`tests/examples/over_wrapper.sh`) | - | - |
| Scope of the base contract | IPv6 is supported | check `ipv6_loopback` | 0 | `Ipv6Unsupported` |
| Scope of the base contract | A provider without extras conforms | inspection: the in-memory provider supplies only the operations of `require_provider` and passes `tests/conformance/run.sh` | - | - |
<!-- scenarios:end -->

### Scenarios added by `harden-memory-provider`

That change added the requirement *A refused send is always resolved* to the contract. Its scenarios are proved
as follows; the first needs an ordering a provider's calls cannot make, so it is a test of the in-memory
provider.

| Scenario | Proved by | Fault |
|---|---|---|
| The write side is shut while a Writable is owed | `tests/unit/memory_ordering_test.goose` and `tests/unit/memory_data_test.goose` (in-memory provider) | (the tests fail when the fix is undone) |
| The write side is shut after a refusal | check `full_not_writable_after_shutdown_write` | `WritableAfterShutdown` |
| The peer closes while a send is refused | check `full_resolved_when_peer_closes` | `FullUnresolvedOnPeerClose` |
| The retry after the peer is gone | check `full_resolved_when_peer_closes` | `FullUnresolvedOnPeerClose` |

### What cannot be shown by a fault

`events_not_reentrant` (*A close does not re-enter the handler*) and `events_not_reentrant_after_reset` (*A send that closes
the link does not re-enter the handler*, in the abort group) have no fault in the in-memory provider. An operation of a queue-based provider has no handler to call, so
it cannot be made to deliver an event from inside itself. The check is the driver's own guard: every check runs
under a counter of handler nesting, and the check fails if an event arrives while another is being handled. The
guard is shown to work by `tests/conformance/reentry_test.goose`, which tells the driver that a handler is already
running. A provider that delivers an event from inside an operation fails the suite at whichever check is running.

A few scenarios depend on a limit a socket provider cannot be asked to reach (*Handles run out and do not wrap*,
*A provider out of links*). They are tested on the in-memory provider and, for a socket provider, answered in its
mapping document under `docs/providers/`.

`dial_while_draining` is complete only when the fixture supplies an address that still answers after `stop`
(`Fixture.answers`): every listener of the loop has stopped by then, so no call can make one. Without it the check
proves that the dial still ends in exactly one event and does not extend the grace period.
