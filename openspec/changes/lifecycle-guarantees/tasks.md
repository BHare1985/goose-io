# Tasks

## Ground rules

These apply to every task:

- Work on a branch, not `main`.
- Write the test before the code it tests, and run it against the old code to see it fail.
- For a check of the suite, "see it fail" means its fault makes it fail (`tests/conformance/faults.sh`).
- A test that fails once in any repetition is a failure until its cause is explained.
- Nothing here adds C, an `extern` or a build sidecar.
- Use the contract's words: `tests/checks/vocabulary.sh` fails on the old ones.
- Run `goose check` after every edit to a `.goose` file.
- Each new check gets a row in `tests/conformance/checks.tsv`, with its part, requirement, scenarios, fault and group. It also gets a row in a new section of `docs/event-loops.md`, "Scenarios added by the lifecycle guarantees", outside the `scenarios:begin`/`end` block that `table_check.sh` counts.
- No check and no document gives a meaning to a `ListenError` code.
- Do not push or tag without the owner's approval.

## 1. Order and baseline

- [x] 1.1 Confirm that `link-keyed-state` is archived. Verify by running `openspec list --json`: it no longer lists `link-keyed-state`, and `openspec/specs/io-contract/spec.md` contains `### Requirement: Slot numbers are dense`. If it is not archived, stop and ask the owner whether to wait, or to go first and add the `set_user` row (like `pause_reading`) and the `user` row (like `peer_address`), as the proposal describes.
- [x] 1.2 Amend the dense-slot bound for retired slots:
  - If *Slot numbers are dense* is in the main spec, add a `## MODIFIED Requirements` block for it to this change's `specs/io-contract/spec.md`. Copy the whole block and add "plus the slots the event loop has retired" to the bound.
  - If it is not, make the same edit in `link-keyed-state`'s delta.
  - Verify `openspec validate lifecycle-guarantees --strict` passes.
- [x] 1.3 Run every command in `CONTRIBUTING.md` on the branch before any change. Verify all pass, and record the output of `tests/conformance/run.sh` as the baseline.

## 2. Handles: the invalid link, pairs and slots

- [x] 2.1 Write the tests first, in `tests/unit/memory_links_test.goose`:
  - for both scenarios of *The in-memory event loop retires an exhausted slot*:
    - age a free slot to `0xffffffff` with `age_slot`, issue and close a link in it, and check that no later link uses the slot or has generation 0;
    - retire a slot and open four link ends with `max_links` of 4;
  - for *The invalid link is reserved*: `send`, `close` and `pause_reading` on `Link {}` affect no link.

  Verify the file fails to compile, because `age_slot` does not exist.
- [x] 2.2 In `memory.goose`:
  - in `_release`, retire the slot when the released generation is `0xffffffff` instead of wrapping it;
  - add the scripting function `age_slot(slot, next_gen)`, documented as not part of the contract;
  - state the retirement in the loop's list of limits.

  Verify the tests of 2.1 and every `tests/unit/memory_*` pass.
- [x] 2.3 Write tests first in `tests/conformance/driver_test.goose`:
  - a pair seen again after its `Closed` fails `handles_pair_unique`, naming the slot and generation;
  - a generation-0 link fails `handles_pair_unique`;
  - a new pair in a slot whose `Closed` is pending fails `handles_slot_held`;
  - a dialled handle followed by its `Opened` fails neither.

  Verify they fail. Then make the driver in `conformance/suite.goose` and `conformance/support.goose` keep one record per issuance, as `design.md` describes, and verify the driver tests pass.
- [x] 2.4 Add the checks `handles_pair_unique` (*A slot and generation pair is never issued twice*, and the first scenario of *The invalid link is reserved*) and `handles_slot_held` (*A slot is held until its Closed is delivered*) to `checks.tsv`, both in group core.
  - Add the faults `GenerationNotAdvanced` and `SlotFreedOnClose` to `memory.goose`. `SlotFreedOnClose` frees the slot at `close` and still advances the generation.
  - In group suites, a violation fails the run with a driver `FAIL` line.
  - Verify that `faults.sh` shows `handles_pair_unique` failing only under `GenerationNotAdvanced` and `handles_slot_held` failing under `SlotFreedOnClose`, and that `groups_check.sh` and `table_check.sh` pass.
- [x] 2.5 Document the three rules (the reserved invalid link, pairs, slots held until `Closed`):
  - `docs/contract.md`: the `Link` row of section 3, and the handle paragraph of section 4, next to the listener rule;
  - `docs/event-loops.md`: list them among the obligations.

  Verify `tests/checks/docs.sh` passes.

## 3. Link states and how operations complete

- [x] 3.1 Create `conformance/states.goose` with the core checks, each wired into `step` and `group_of` in `conformance/suite.goose`:
  - `states_send`: *Sending has one result in each link state*, "One link in each state"; also both scenarios of *A link is in one of five states*;
  - `states_closed_is_final`: the first two scenarios of *A Closed send result is final*;
  - `states_close`: "Close twice";
  - `states_pause`: *Pausing takes effect in every live state*;
  - `states_completion`: "Pausing is complete when it returns" and "One Tick may answer several requests".

  Run `tests/conformance/run.sh` and confirm that each passes on the in-memory loop. Where a check fails, the in-memory loop has a defect: fix it in `memory.goose`, with a unit test written first.

  Applied as: ids 350 to 355 (core part 0 runs in id order and ends with the `stop` check at 505, so a check must have a lower id), and `states_closed_is_final` is split in two (`states_closed_wakes_nothing`, the refused-send scenario, so that the Writable fault has its own check). No defect of the in-memory loop was found.
- [x] 3.2 Add one fault to `memory.goose` for each core check of 3.1, and give each check its row in `checks.tsv`:
  - `PauseBeforeOpenIgnored`: `pause_reading` on a dialling slot is dropped;
  - `SecondCloseClosesAgain`;
  - `WritableAfterClosedResult`;
  - `ClosedResultNotFinal`: a send after a `Closed` result returns `Sent`;
  - for `states_send`, reuse `SendBeforeOpenSent`;
  - for `states_completion`, reuse an existing tick fault (such as `TickEvery250`) where it breaks the scenario, and say so in the row.

  Verify `faults.sh` shows each check failing under its fault.
- [x] 3.3 Move every `set_keep_open_on_eof` call that runs after its link's own `Opened` handler into that handler, or before `Opened` for a dialled end:
  - in `conformance/`: `c_half_close_then_answer` (`close.goose:186`) and `c_full_resolved_when_peer_closes` (`data.goose:451`);
  - in `tests/unit/`: the calls in `memory_close_test.goose` (around lines 75, 123, 229 and 270) and `memory_ordering_test.goose:48`.

  Add a helper to `tests/support/kit.goose` if it shortens the pair-based tests. Leave the stale-handle calls (`memory_close_test.goose:366`, `memory_ordering_test.goose:176`) as they are. Verify `tests/run_tests.sh` and `tests/conformance/run.sh` still pass on the unchanged loop. Also run `grep -rn set_keep_open_on_eof conformance tests examples` and confirm that every remaining call is in an `Opened` handler, before `Opened`, or on a stale handle.
- [x] 3.4 Implement the keep-open window in `memory.goose`:
  - add a per-slot `configured` flag, set by `serve` when the handler of that slot's `Opened` returns;
  - make `set_keep_open_on_eof` do nothing on a configured slot;
  - make the end-of-stream decision for a slot only once it is configured.

  Write the unit tests first in `tests/unit/memory_close_test.goose`, one for each of the four scenarios of *Keep-open is configured no later than Opened*, and verify that "A late call has no effect" fails before the change. Verify that all four pass after it.
- [x] 3.5 Add the half-close checks to `conformance/states.goose`, each with its fault and its `checks.tsv` row:
  - `states_half_close`: "Sending on a write-shut link" without `send2`, "Shutdown before the link opens", "Close after shutdown", "Shutdown is complete when it returns", and "After shutdown a Closed result concerns only sending". Faults: `ShutdownBeforeOpenRemembered`, `ClosedResultEndsShutLink` (a send after `shutdown_write` closes the whole link).
  - `states_keep_open`: the four scenarios of *Keep-open is configured no later than Opened*. Faults: `KeepOpenWhileDiallingIgnored`, `KeepOpenLateHonoured`, `EarlyEofActedOn` (an end of stream seen before the `Opened` handler returns is acted on by the old setting).

  Verify that `faults.sh` shows each check failing under each of its faults. (The fault column of `checks.tsv` may now list several faults, separated by commas; `faults.sh` and `table_check.sh` try each one. The half-close checks are ids 360 and 361.)
- [x] 3.6 Add the other group checks to `conformance/states.goose`, each with its fault and its `checks.tsv` row:
  - `states_sizing` (sizing): `send2` and `send_room` while dialling, open, closing and ended. Fault: `RoomWhenClosed`, or a new one if it does not break every cell. The write-shut cell is a unit test in `tests/unit/memory_data_test.goose`.
  - `states_reset` (abort): "Reset a dial in progress" and "Reset after close". Faults: `ResetDialOpens`, `ResetAfterCloseClosesAgain`.
  - `states_inspection` (inspection): `peer_address` while dialling, open, closing and ended, which covers the new scenarios of *A link reports its peer's address*. Fault: `PeerAddressGoneOnClose`. The write-shut cell is a unit test of the in-memory loop.

  Record in `docs/event-loops.md` that batching and unix have no link operation and no states check. Verify that `groups_check.sh` reports no check calling an operation outside its group, and that `faults.sh` passes.
- [x] 3.7 Run the states checks on the layers. Verify that `tests/conformance/run.sh --wrapped` and `--core-only` pass, and that `--repeat 5` gives identical output.
  - If the wrapper fails "Pause before Opened" because it delays `Opened`, fix it to keep the pause it passed to the inner loop.
  - Likewise for the keep-open window: the wrapper keeps every inner link open on end of stream, so its own `configured` point must be its delayed `Opened`.
- [x] 3.8 Document:
  - `docs/contract.md`, "The life of a link": the operation × state table and the completion table from `design.md`. "Sending and backpressure" gets the two meanings of a `Closed` result. The half-close section states the keep-open window, and the inspection section the `peer_address` states.
  - `docs/libraries.md`: set keep-open in `Opened`, or before it for a dialled link; on a `Closed` send result, drop the send queue, but expect `Data` until the `Closed` event.
  - `docs/event-loops/io-uring.md`: a note that an end of stream completed before `Opened` is held until the `Opened` handler returns.

  Verify that `tests/checks/docs.sh`, `tests/checks/event_loops.sh` and `tests/checks/vocabulary.sh` pass.

## 4. The life of a loop

- [ ] 4.1 Write the tests first, in `tests/unit/memory_loop_test.goose`:
  - after `serve` returns: `send`, `send2`, `send_room`, `listen`, `dial`, `close`, `reset`, `pause_reading`, `tick_by`, `draining` and `now_ms` give the results of *A finished loop does nothing*, and `dial` returns `Link {}`;
  - a second `serve` never calls its handler;
  - a listen and a dial made before `serve` deliver `Opened` from `serve` and nothing before it.

  Verify the second-`serve` and finished-`dial` tests fail against the current loop, and record which of the others already pass.
- [ ] 4.2 In `memory.goose`, add `_finished`, set when `serve` returns. Every operation checks it first, as `design.md` describes: `dial` returns `Link {}`, `listen` returns kind `Other`, and a second `serve` returns at once. Verify the tests of 4.1 pass.
- [ ] 4.3 Make `tests/support/wrapper.goose` drop the events it still holds when the inner `serve` returns, and pass the finished-loop results through. `tests/support/core_only.goose` passes them through unchanged. Write the test first in a new `tests/unit/wrapper_loop_test.goose`, and verify it passes.
- [ ] 4.4 Add a pre-`serve` hook to `_run_part` in `conformance/suite.goose`, and add the check `setup_before_serve` (core, part 0, *A loop is set up, serving, draining or finished*), which listens and dials in the hook. Write its driver test first in `tests/conformance/driver_test.goose`. Add the fault `SetupEventsDropped`: events queued before `serve` are discarded. Verify `faults.sh` shows the check failing.
- [ ] 4.5 Add `finished_loop` to core part 1. In its `after` step it calls every core operation, requires `is_valid(dial(...))` to be false, and calls `serve` a second time. Its faults are `SendAfterFinishSent`, `FinishedDialIssues` and `SecondServeRuns`.
  - Then, for each group suite, find out whether its part 0 ends with `serve` returning before the driver's `after` step.
  - Where it does, add `finished_loop_<group>`, covering that group's operations.
  - Where it does not, record in `checks.tsv` that the group's finished-loop cells are covered by the unit tests of 4.1.

  Verify `faults.sh`, `groups_check.sh` and `table_check.sh` pass.
- [ ] 4.6 Add the check `grace_keeps_local` as core part 6 (*The end of the grace period*, both scenarios). It uses two pairs: one closed before `stop`, and one closed after `stop` within the grace period, each with a paused peer. Its fault is `ShutdownOverridesLocal`. Confirm that `run.sh` and `faults.sh` pick up part 6 from `checks.tsv`, and edit them if they do not. Verify that `tests/conformance/run.sh` runs parts 0 to 6, and that `faults.sh` shows the check failing for both pairs.
- [ ] 4.7 Record the threading rule:
  - rewrite the thread paragraph of `docs/contract.md` section 1 to *A loop belongs to the thread that serves it*;
  - inspect `examples/gateway.goose`, the tests' root programs and the suite's entry points, and confirm that each sets up and serves on one thread;
  - record "Setting up on the serving thread" in the new section of `docs/event-loops.md` as an inspection step, naming the files inspected.

  Verify `table_check.sh` and `docs.sh` pass.
- [ ] 4.8 Document:
  - `docs/contract.md`, "Running and stopping": the four loop states, the finished-loop list (with `dial` returning the invalid link), and the end of the grace period (no promise of delivery; `Local` stands whether the close came before or after `stop`).
  - `docs/libraries.md`: do not count on delivery at the end of the grace period; check `is_valid` on a `dial` made after `serve` might have returned.
  - `docs/event-loops.md`: a section "What the lifecycle guarantees added", listing the obligations: the reserved invalid link, retirement, slots held until `Closed`, the keep-open window, reading controls while dialling, `Closed` is final, the finished loop, and `Local` over `Shutdown`.

  Verify `docs.sh` and `vocabulary.sh` pass.

## 5. Version and integration

- [ ] 5.1 Set `VERSION_MINOR` in `goose_io.goose` as `design.md` decides: the same minor as `link-keyed-state` if neither has been released, otherwise one above the value on `main`. Update:
  - the expectation in `tests/unit/groups_test.goose`;
  - the version paragraph of `docs/contract.md` section 9, saying what this version adds and that the keep-open window is a tightening;
  - the version column of the `README.md` table.

  Verify `tests/run_tests.sh` and `docs.sh` pass.
- [ ] 5.2 Run every command in `CONTRIBUTING.md`, then `tests/conformance/run.sh --repeat 50`, `--wrapped --repeat 10` and `--core-only --repeat 10`. Verify that all pass, that the output of every repetition is identical, and that `openspec validate lifecycle-guarantees --strict` passes.

## Workflow follow-up

- Archive the change once the owner has reviewed it, and check that the main `io-contract` and `provider-conformance` specs contain the new requirements and the modified *A link reports its peer's address*.
- Tell the owner of `epoll-event-loop` about the new obligations (section "What the lifecycle guarantees added" of `docs/event-loops.md`), so its design and tasks can take them in.
- Propose the two follow-up changes named in `proposal.md`: the runtime contract monitor, and the varying mode of the in-memory loop.
