# Design

## Context

See `proposal.md` for why. This is what the code does today and what constrains the approach:

- **Generations.** The in-memory loop frees a slot in `_release` (`memory.goose:957`), once the link's `Closed` has been delivered, so a slot is never reissued while its `Closed` is pending. The generation is incremented there, and it wraps: `s.gen++; if s.gen == 0 { s.gen = 1; }`. Generation 0 is never issued, and `Link {}` (slot 0, generation 0) is the contract's default, invalid value (`goose_io.goose`, `is_valid`). Listener handles already fail with `NoResources` rather than wrap (`memory.goose:493`). Links need the same treatment.
- **Operations in each state.** Most results are already in the code, but not in the contract:
  - `pause_reading` and `set_keep_open_on_eof` act on any slot that is not free, dialling included (`memory.goose:635`, `704`), and so does a late `set_keep_open_on_eof` today.
  - `shutdown_write` acts only on an open link that is not already shut (`:714`).
  - `close` and `reset` do nothing once the slot is closed (`:689`, `:698`).
  - `peer_address` answers for any slot whose `Opened` was delivered and that is not yet free (`:604`), so a closing link already names its peer. The main spec's wording ("empty for a link that is not open", but also "available until `Closed` is delivered") disagrees with itself on that state.
- **Late keep-open calls.** Several callers set keep-open after the link's own `Opened` handler, when "the pair is open", which means inside the handler of whichever end opened second:
  - in `conformance/`: `c_half_close_then_answer` (`close.goose:186`) and `c_full_resolved_when_peer_closes` (`data.goose:451`);
  - in `tests/unit/`: the uses after `kit::track` in `memory_close_test.goose` (around lines 75, 123, 229 and 270) and `memory_ordering_test.goose:48`.

  They work only because the peer has not finished yet. `examples/lineserver/server.goose:152` calls it from its accept path, inside `Opened`. The calls on stale handles (`memory_close_test.goose:366`, `memory_ordering_test.goose:176`) test that a call has no effect, and stay.
- **End of the grace period.** `_run_due` closes every library link that is left with `Shutdown`, gracefully (`:787`). A link the library had closed is already `_CLOSED` by then, because in memory a close completes at once. So nothing on main can show the `Local`-over-`Shutdown` rule failing: the fault has to make a close linger.
- **Running twice.** `_start` is guarded, but nothing stops a second `serve` from running passes and delivering `Tick`s. What operations do after `serve` is whatever state the drain left behind.
- **The suite.**
  - The driver (`conformance/suite.goose`, `_run_part`) already gives a check one more step after `serve` has returned (`k.after`). Parts 1 to 5 of the core each run one `stop` scenario.
  - Checks track their links by tag (`conformance/support.goose`, `track`). The `link-keyed-state` change replaces this with tracking by link.
  - `tests/conformance/checks.tsv` maps each check to its requirement, scenarios, fault and group. `table_check.sh` and `groups_check.sh` enforce the table.
- **Layers.** Goose does not allow a root struct to be owned by another struct ("nested root owners are not supported"; checked with a compile test of `root struct Mon<Io> { inner: Io }`). The wrapper and the core-only loop therefore keep their inner loop in a module global. This is why the runtime monitor is left to its own change.

## Goals / Non-Goals

**Goals:**
- Every cell of the link-state table, and every finished-loop rule, is backed by a check that fails on a named fault.
- The in-memory loop, the wrapper and the core-only loop all pass the new checks. No library source changes beyond moving keep-open calls into `Opened`.
- An epoll loop, an io_uring loop and the in-memory loop can all meet the rules without imitating each other, and no rule leaves a result to when a loop happens to notice an event.

**Non-Goals:**
- Changes to operation signatures, events or groups.
- A cross-thread wake, descriptor readiness, a contract monitor, a census of loop state, or a varying mode for the in-memory loop (see `proposal.md`).
- Checking the threading rule at run time. It is an obligation on the application, recorded as an inspection step.

## Decisions

**The states are the library's view, not the loop's.**

| State | Means |
|---|---|
| dialling | `dial` returned, no event yet |
| open | after `Opened` |
| write-shut | after `shutdown_write` |
| closing | after `close` or `reset`, before `Closed` |
| ended | after `Closed`, or a handle never issued, the invalid link included |

A library can tell each state from its own calls and events. The loop may be ending an open link early: the peer has gone, or an idle limit has passed. The table allows for that by letting `send` on an open link return `Closed`, rather than adding a sixth state that a library cannot observe.

- Rejected: the loop's internal states, such as the in-memory loop's `_OPENING` (connected, `Opened` not yet delivered) or epoll's "fd registered, connect pending". They differ between loops, and naming them would make the contract describe epoll.
- Rejected: a "peer finished" state for half-close. After `PeerEof`, every operation behaves as it does on an open link except `set_keep_open_on_eof`, and that one has stopped having an effect as soon as the `Opened` handler returned (below). So the column would be identical to "open".
- Rejected: an "inside the `Opened` handler" state. The only operation that depends on it is `set_keep_open_on_eof`, so it is a timing rule on that row, not a column.

The table goes into `docs/contract.md`, "The life of a link":

| Operation | dialling | open | write-shut | closing | ended |
|---|---|---|---|---|---|
| `send`, `send2` | `NotOpen` | `Sent`/`Full`/`TooLarge`, or `Closed` if the loop is ending it | `Closed` | `Closed` | `Closed` |
| `send_room` | 0 | room | 0 | 0 | 0 |
| `close`, `reset` | cancel; one `Closed` `Local` | end; one `Closed` `Local` | end; one `Closed` `Local` | no effect | no effect |
| `shutdown_write` | no effect | ends sending | no effect | no effect | no effect |
| `pause_reading` | recorded | takes effect | takes effect | no effect | no effect |
| `set_keep_open_on_eof` | recorded | recorded only while handling `Opened`; no effect after | no effect | no effect | no effect |
| `peer_address` | empty | address | address | address | empty |

The spec states the table in one requirement per row family, so each stays under the length limit and has its own scenarios.

**Coverage, group by group.** Each state check runs in its group's suite and calls only that group and the core (*The suite is run one group at a time*):

| Group | Link operations | States check | Cells it cannot reach, and where they are tested |
|---|---|---|---|
| core | `send`, `close`, `pause_reading` | `states_send`, `states_close`, `states_pause`, `states_closed_is_final`, `states_completion` | write-shut (needs half-close): `states_half_close` |
| half-close | `shutdown_write`, `set_keep_open_on_eof` | `states_half_close`, `states_keep_open` | none |
| sizing | `send2`, `send_room` | `states_sizing` (dialling, open, closing, ended) | write-shut: `tests/unit/memory_data_test.goose` |
| abort | `reset` | `states_reset` | none |
| inspection | `peer_address` (`stop_listening` takes a listener, not a link) | `states_inspection` (dialling, open, closing, ended) | write-shut: a unit test of the in-memory loop |
| batching | none, an event only | none | |
| unix | none, address forms only | none | |

**A `Closed` send result is final for sending. It means the link is ending only if the library had not ended sending itself.** After `shutdown_write`, `send` returns `Closed` while the link goes on receiving, possibly for an hour. So finality is stated about the write side: no later send is taken, `send_room` is 0, and no `Writable` follows. The stronger meaning, "the event loop is ending this link and its `Closed` follows with no further call", applies only when the library had called none of `shutdown_write`, `close` and `reset`. In that case a loop returns `Closed` only once it has started ending the link (the peer reset it, a write failed, or a limit passed), so every loop already behaves this way. The rule stops a later loop from returning `Closed` for a transient condition. With these keywords, a library can drop its send queue on any `Closed` result, and can stop expecting more `Data` only on the `Closed` event.
- Rejected: a new `SendStatus` for write-shut. That would change a signature, and `Closed` already means "write-shut" in the type's comment (`goose_io.goose`).

**`set_keep_open_on_eof` is configuration with a fixed window: dialling, or inside the link's `Opened` handler.** The setting applies when the `Opened` handler returns, and a later call has no effect even if the peer has not finished. A loop that saw the peer's end of stream before then waits until the handler returns and then acts on it as the setting says.

A window that lasted "until the end of stream is acted on" would make the result depend on when each loop notices the end of stream:
- an io_uring loop may hold the end-of-stream completion before it delivers `Opened`;
- an epoll loop may not have read it yet.

That is exactly the kind of cross-loop difference this change removes. With the fixed window, every loop answers the same way. The cost is one flag per link, plus holding an observed end of stream back until the `Opened` handler returns. Event order already requires that, since `Opened` comes first.

How the in-memory loop does it: a per-slot `configured` flag, set by `serve` when the handler of that slot's `Opened` returns. `set_keep_open_on_eof` does nothing on a configured slot, and the end-of-stream decision for a slot is made only once it is configured. In-repo callers that set the option late move into the link's own `Opened` handler, or before `Opened` for a dialled end. The test kit gains a helper so that the pair-based tests can do this in one line.
- Rejected: an error result for a late call. It would change the signature, and "no effect" already matches how the contract treats every misplaced call.
- Rejected: keeping the current lenient behaviour. Libraries tested only on the in-memory loop would set it late and break on io_uring.

**`pause_reading` takes effect while dialling.** A proxy dials a backend and wants it paused from the first byte.
- epoll records the flag on the slot and does not arm `EPOLLIN`.
- io_uring does not submit the first receive.
- The in-memory loop already behaves this way.

**`shutdown_write` on a dialling link has no effect.** This matches the existing precondition ("link is open") and the in-memory loop. The alternative, remembering the call and shutting the link once it opens, would add hidden state to every loop for a call no example makes.

**`reset` after `close` does not produce a second `Closed`. Whether it cuts short a close that is still sending is the loop's choice.** On epoll a lingering close could be aborted, but in memory a close completes at once. The check tests only that exactly one `Closed`, with `Local`, arrives.

**Completion: what a call returns, and the one notification some calls have.** The libuv distinction between a handle and a request maps onto events the contract already has. No request objects are added: a request handle would be a second identity beside the `Link`.

| Operation | Returns with | Later notification |
|---|---|---|
| `listen` | a listener, or an error; no event follows an error | none of its own; each accepted connection is a new link's `Opened` |
| `dial` | a link (the invalid link on a finished loop) | one `Opened` or `Closed` (none on a finished loop) |
| `send`, `send2` | a `SendStatus`; `Sent` means taken, not delivered | after `Full`: one `Writable` or the link's `Closed` |
| `close`, `reset` | nothing; effective at once (sends return `Closed`) | one `Closed`, `Local` |
| `shutdown_write` | nothing; effective at once | none of its own; the link's `Closed` comes when both sides are done |
| `pause_reading`, `set_keep_open_on_eof` | nothing; effective at once (keep-open: applied when `Opened` returns) | none |
| `tick_by` | nothing; the request is recorded | a `Tick` at or after the earliest outstanding request. One `Tick` may answer several calls, and regular `Tick`s come anyway, so it is not one-to-one |
| `stop` | nothing; draining begins at once | `serve` returns |
| `stop_listening` | nothing; no connection is accepted after it | none |
| `listener_port`, `max_send`, `send_room`, `peer_address`, `now_ms`, `draining` | their value | none |

**The invalid link is a contract value. `dial` on a finished loop returns it.** `Link {}` (slot 0, generation 0) is already the default and is already invalid by `is_valid`. The new requirement makes it reserved: no loop issues generation 0, and every operation treats generation 0 as a handle that was never issued.

On a finished loop `dial` returns that value. It issues no link, so uniqueness is untouched. It starts no connection and produces no event. The library can tell it apart at once, because `is_valid` is false. This is stated as the one exception to *Dialling never blocks and always ends in one event*. That requirement is modified by `link-keyed-state`, so the exception lives in the finished-loop requirement and not in a second edit of it.
- Rejected: a fresh pair in the ended state. That would be an issued link that never gets `Closed`, which contradicts the lifecycle. It also uses up generations, and the in-memory loop would have to mint distinct terminal pairs.

**Handles: two rules, two checks.**
1. *A slot and generation pair is never issued twice*: retire the slot instead of wrapping it.
2. *A slot is held until its `Closed` is delivered*: a slot names at most one link that has not ended.

Neither implies the other. A loop could advance the generation and still hand out the slot while the old link's `Closed` is pending: that keeps rule 1 and breaks rule 2. A loop could also reuse the generation after `Closed`: that keeps rule 2 and breaks rule 1. `link-keyed-state`'s `LinkMap` relies on both.

- Rule 1 is stated as a property, so that a loop may use any scheme. A loop with 64-bit internal counters that hands out the low 32 bits must still retire.
- In the in-memory loop, `_release` retires the slot when the released generation is `0xffffffff`, and `_new_slot` grows a new slot. `max_links` counts live link ends, not slots, so retirement does not lower the limit.
- A scripting hook, `age_slot(slot, next_gen)`, is not part of the contract.
- Rejected: wrapping and relying on 2^32 being large. With a LIFO free list and short connections, one slot can take nearly all reuse. At 100k connections a second that slot wraps in about 12 hours, and a pool that holds a handle that long would reach the wrong link.

**The driver checks both handle rules continuously.** It keeps one record per issuance, `(slot, gen, closed_delivered)`. An issuance is the first sighting of a pair: the handle `dial` returned, or the `Opened` of an accepted link. A later sighting of a live pair (a dialled link's `Opened`, any later event) is the same issuance.
- `handles_pair_unique` fails when a pair is seen as a new issuance after its `Closed` was delivered, or when a pair has generation 0. Its fault is `GenerationNotAdvanced`.
- `handles_slot_held` fails when a new pair appears in a slot whose previous issuance has not had its `Closed`. Its fault is `SlotFreedOnClose`, which frees the slot at `close` and still advances the generation, so it breaks rule 2 and not rule 1.
- Both are tabled once, in the core. In other groups' suites a violation fails the run with a driver `FAIL` line naming the requirement.
- Rejected: one scripted churn check. The driver sees every pattern the suite produces.

**Interaction with `link-keyed-state`'s dense-slot rule.** That rule says no slot is ever as large as the greatest number of links valid at once. A retired slot breaks the bound by one, forever. The fix is to count retired slots in the bound ("...at once, plus the slots the loop has retired"). For a library, a table sized to its peak grows by one entry per retired slot, which happens after 2^32 uses of one slot. Task 1.2 adds the amendment either as a MODIFIED delta here, if `link-keyed-state` is archived, or in that change's delta otherwise.

**Loop-life checks.**
- `setup_before_serve` (core, part 0) listens and dials in a new pre-`serve` hook of `_run_part`. Its fault is `SetupEventsDropped`.
- `finished_loop` (core, part 1, in its `after` step) calls every core operation, requires `dial` to return a link with `is_valid` false, and calls `serve` a second time with a handler that fails if it is called. Its faults are `SendAfterFinishSent`, `FinishedDialIssues` and `SecondServeRuns`. Each group's finished-loop cells are checked the same way where that group's part ends with `serve` returning (task 4.5 finds out), and otherwise by the unit tests of the in-memory loop.
- `grace_keeps_local` (core, new part 6, since one `stop` per process is the existing constraint) uses two pairs. On the first, it sends to a paused peer and closes before `stop(100)`. On the second, it does the same after `stop`, within the grace period. Both must end with `Local`. Its fault, `ShutdownOverridesLocal`, makes a close whose peer has unread bytes leave the slot open, so the grace-end sweep closes it with `Shutdown`.

**The in-memory loop after `serve`.** `serve` sets `_finished` when it returns. Every operation checks it first:
- `send` and `send2` return `Closed`, and `send_room` returns 0;
- `listen` returns kind `Other`;
- `dial` returns `Link {}`;
- everything else returns at once, and a second `serve` returns at once.

The checks and the contract read only the error's kind. `ListenError.code` stays loop-specific, as section 3 of `docs/contract.md` already says, and no check or document gives it a meaning. The wrapper and the core-only loop pass these calls through, and the wrapper also drops any events it still holds.

**The end of the grace period promises nothing about delivery.** Bytes already handed to the transport are not safe either: an abort can lose what the kernel had taken. So the rule says the loop may discard any accepted bytes of a remaining link and may end it gracefully or by abort, and that a library must not assume delivery. A link the library closed before the grace period ended still ends with `Local`, whether the close came before `stop` or during the grace period. *Closing* already says the only event after `close` is one `Closed` with `Local`, and this rule only confirms that the grace period does not override it.

**Versioning.** The new rules add obligations a 0.2 loop might not meet:
- retirement;
- finished-loop behaviour;
- `Local` over `Shutdown`;
- the keep-open window, which is a tightening.

So the minor number goes up. If this change and `link-keyed-state` ship in one release, both are in the next release after main. Otherwise this change takes the minor after whatever main has. Task 5.1 reads `goose_io.goose` at apply time.

**Threading is documented, not enforced.** Goose has threads, but the contract's operations take `Io&` and cannot tell which thread calls them. The rule is the most restrictive one for applications and the most permissive for loops:
- An io_uring loop with `IORING_SETUP_SINGLE_ISSUER` can bind at its first call.
- An epoll loop does not need to.

The scenario is covered by an inspection step recorded in `checks.tsv`. Rejected: setting up on one thread and calling `serve` on another. It costs io_uring a disabled ring that is enabled later, and no example needs it.

## Risks / Trade-offs

- **The keep-open window breaks callers that set it late.** → Within this repository there are two conformance checks and a handful of unit tests, all listed under Context, and they move in task 3.3. Outside it, the migration note in `docs/libraries.md` says to set it in `Opened`. The fault `KeepOpenLateHonoured` keeps the in-memory loop from drifting back.
- **A real loop cannot meet "`Closed` is final" on a link it has not ended.** For example, a loop that returns `Closed` on `EAGAIN` confusion. → That is a bug in the loop. The rule matches every mapping document's reading, and the epoll change's suite run will show whether it holds.
- **Holding an early end of stream until `Opened` returns costs completion loops a little.** → It is one flag. `docs/event-loops/io-uring.md` gains a note.
- **The pre-`serve` hook changes the driver every group uses.** → Make it its own task, with the driver's tests (`tests/conformance/driver_test.goose`) updated first and run against the old driver to see them fail.
- **Retirement makes the dense-slot bound slightly weaker.** → It is unobservable before 2^32 uses of a slot, and it is stated exactly.
- **More core parts mean more processes per run.** → Part 6 is one short check, and `run.sh` already loops over the parts in `checks.tsv`.
- **Applying before `link-keyed-state`.** → The tables would need `set_user` and `user` rows, and the checks track links by tag. Task 1.1 checks the order and stops for the owner's decision.

## Migration Plan

There is no runtime migration: the contract is a source package.
- Event loops outside this repository: today only the planned epoll loop. They read the new section of `docs/event-loops.md`, "What the lifecycle guarantees added".
- Libraries: move any `set_keep_open_on_eof` call into the link's `Opened` handler, or before `Opened` for a dialled link. Do not count on delivery at the end of the grace period.
- Rollback is reverting the change. Nothing else depends on the new checks.

## Open Questions

- Whether `docs/event-loops/*.md` should carry a row for each new obligation, or one note for each document. Either choice leaves the specs and tasks as they are; decide when editing them.
