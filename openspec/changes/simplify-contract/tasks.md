# Tasks

Ground rules for every task: work on the branch `simplify-contract` (made from `contract-v1`), not `main`. Do not push or tag without the owner's approval. Write the test before the code it tests and run it against the old code to see it fail. A test that fails once in any repetition is a failure until its cause is explained. No core rule is weakened (design D3), and no check loses its fault (`tests/conformance/faults.sh` stays at zero checks that pass against their fault). The package stays pure Goose.

## 1. Sequencing

- [x] 1.1 In a scratch copy of the tree, archive `define-contract-v1` and run `openspec validate simplify-contract --strict`; verify the "Archive would refuse this delta: source not found" notes are gone, and record the output in the commit message of 1.2
- [x] 1.2 Archive `define-contract-v1` on this branch (with the specifications synced into `openspec/specs/`) and commit; verify `openspec validate --specs` and `openspec validate simplify-contract --strict` pass and `openspec list` no longer shows `define-contract-v1` as active

## 2. The contract: a core and groups

- [x] 2.1 Write the tests first in `tests/unit/types_test.goose` and a new `tests/unit/groups_test.goose`: `VERSION_MINOR` is 2; `require_core` compiles for the in-memory loop and each `require_` group check does too (`require_half_close`, `require_sizing`, `require_abort`, `require_inspection`; the batching group has no operation to name, so no check); `CloseReason.LoopSpecific { code }` exists and `is_portable` is false for it; a `*_mustfail.goose` stub that lacks `send2` passes `require_core` and fails `require_sizing` with an error that names `send2`; verify these fail to build on the current `goose_io.goose`
- [x] 2.2 In `goose_io.goose` replace `require_provider` by the five checks of design D4, rename `Provider { code }` to `LoopSpecific { code }`, set the version to 0.2 and rewrite the comments in the new words; update every caller; verify 2.1 passes and `goose check goose_io.goose` is clean

## 3. The in-memory loop and the wrapper

- [x] 3.1 Spike, in scratch files outside the repository: a driver generic over a group marker type, with `info` and `step` overloaded on the marker, in which instantiating the core entry point for a stub loop that has only the core compiles and a check that calls `send2` is not instantiated; record the result in `design.md` D5; if it does not work, record the fallback used instead and change task 4.1 to match
- [x] 3.2 In `memory.goose` rename `provider_close` to `close_with_reason` and rewrite the comments and `Config` notes in the new words; update the tests that call it; verify `tests/run_tests.sh` passes
- [x] 3.3 Rewrite `tests/support/wrapper.goose` in the new words and make it call the core check and the check of each group it supplies; verify `tests/conformance/run.sh --wrapped` and `tests/examples/over_wrapper.sh` still pass

## 4. The suite by group

- [x] 4.1 Make the driver generic over a group marker (the result of 3.1), add `group` as a column of `tests/conformance/checks.tsv`, and give the core and the batching group an entry point (`conformance_core_part`, `conformance_batching_part`; the others follow in 4.4 when they have checks, and `conformance_part` stays as a transitional entry point for everything until then); move the 28 checks that call no operation outside the core to the core and the 2 `PassEnd` checks to batching (design D5), and run them; verify `tests/conformance/run.sh --group core` and `--group batching` pass, `run.sh` still passes for everything, and a stub loop with only the core builds the core entry point (`tests/conformance/core_builds_test.goose`, which fails when a core check calls `send2`)
- [x] 4.2 Remove the incidental extras from checks that are about the core: add the fixture field `refused` and use it in `dial_refused`; move the `send2` lines of `send_before_open` and `send_after_close` to the sizing check of the same requirement; give `listen_stop_keeps_links`, `listener_handle_never_reused`, `listen_port_zero` and `ipv6_loopback` the group their subject names (inspection) or rewrite them with core calls; verify every check of the core calls no operation of a group (a script, `tests/conformance/groups_check.sh`, that reads the calls of each check) and that `faults.sh` still has no check that passes against its fault
- [x] 4.3 Split the checks that call several groups (`reset_aborts_the_peer`, `send_room_is_zero_when_closed`, `handles_stale_reuse`, `handles_unset`) and `handles_valid_in_closed` into a core check and a check of each group, each with a fault; verify `groups_check.sh` reports no check that calls more than the core and one group
- [x] 4.4 Move the remaining checks of the groups into their entry points and give each group a runner (`tests/conformance/run.sh --group half-close` and so on, default all) that builds only that group's entry point against the in-memory loop; verify every group passes, `run.sh --repeat 50` has zero failures, `faults.sh` shows every check failing against its fault, and `table_check.sh` still names every scenario
- [x] 4.5 Update `docs/providers.md` (becomes `docs/event-loops.md` in 6.3) for the suite by group: the entry points, the fixture's `refused` field, how to read the group of a failure, and the rule for being listed as conforming by group; verify `tests/checks/docs.sh` passes, with the quoted root program the one the tests run

## 5. A loop with only the core

- [x] 5.1 Write `tests/support/core_only.goose`, a loop over the in-memory loop that supplies the 13 operations and 5 events of the core and nothing else, and a test that runs the core suite on it in its own process and a `*_mustfail.goose` that builds the sizing entry point on it and fails naming an operation; verify both
- [x] 5.2 Make each example library say what it needs in its header (client: core; server: core and half-close; gateway: both), have each library's test call the matching `require_` check, and run the client's tests on the core-only loop; verify the client's tests pass on it and the server's fail to build on it naming `set_keep_open_on_eof`
- [x] 5.3 Extend `tests/examples/over_wrapper.sh` and `imports_test.sh` for the above and add a script, `tests/examples/needs_check.sh`, that fails when a library's header names fewer groups than the operations it calls; verify it passes, and fails when a call is added in a scratch copy

## 6. Words and documents

- [x] 6.1 Write `tests/checks/vocabulary.sh` first: it fails on "provider" or "host" in the documents, code, scripts and `openspec/specs/`, outside the allowed lines (design D10), and runs in `tests/run_tests.sh`; verify it fails now and lists the files
- [x] 6.2 Sweep the code, tests and scripts for the old words (names, comments, messages, the output of the suite) in the order of the lists the script prints; verify the script reports nothing for them and `tests/run_tests.sh` passes
- [ ] 6.3 Rewrite `docs/contract.md` around the core and the groups (the core first, each group in its own section with its rules), rewrite `docs/libraries.md`, `README.md` and `CONTRIBUTING.md` in the new words, move `docs/providers.md` to `docs/event-loops.md` and `docs/providers/` to `docs/event-loops/`, and update the README layout section and every caller; verify `tests/checks/docs.sh`, `layout.sh` and `vocabulary.sh` pass
- [ ] 6.4 Regroup the rows of each mapping document into the core and the groups, add to each a section "What a loop with only the core costs" listing the core's adapter work, and update `tests/checks/providers.sh` for the new layout; verify it passes and every document has the section
- [ ] 6.5 Sweep the requirements of `openspec/specs/` that this change does not restate (the in-memory loop's requirements and the others whose wording is the only change) for the old words, edited in place, and shorten any requirement over 500 characters that this change restated; verify `openspec validate --specs` passes with no warning and `vocabulary.sh` passes

## 7. CI and acceptance

- [ ] 7.1 Make `.github/workflows/ci.yml` and `CONTRIBUTING.md` run the core and each group, the core-only loop, the groups check, the needs check and the vocabulary check; add the groups to the README's table of conforming loops; verify every `run:` command of the workflow and every command of `CONTRIBUTING.md` exits 0 locally
- [ ] 7.2 Run everything from a fresh clone of the branch, then `openspec validate simplify-contract --strict`; verify both succeed and record the Goose version and the commit in `docs/history.md`
- [x] 7.3 Run the macos-arm64 build of `.github/workflows/ci.yml` on `macos-26`, because the label `macos-15` is never picked up for this private repository (the job stays queued); verify the first run of all four builds (linux-x64, macos-x64, macos-arm64, windows-x64) passed on GitHub, and that 7.1's edits to the workflow keep the label
- [x] 7.4 Run one CI job set for each commit: `push` only for `main`, `pull_request` for branches, and a `concurrency` group that cancels a superseded run, because a branch with a pull request ran twice on every commit and the second macos-arm64 job was cancelled while waiting for a runner (GitHub: capacity constraints on macOS arm64); verify a push to a pull request branch starts one run, and that 7.1's edits to the workflow keep these triggers

## Workflow follow-up

- Archive this change after acceptance and verify the archived specifications say event loop throughout.
- Merge to `main`, push and tag only with the owner's approval.
- Next changes, in the owner's order of priority: the tcprouter-engine example loop (with parity gates), the uSockets example loop, the io_uring example loop. Each starts from the core and adds groups as it needs them.
- `define-io-contract`, the superseded change, is still to be reworked or removed by the owner's decision.
