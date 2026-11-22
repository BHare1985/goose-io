# Tasks

Ground rules: work on a branch of goose-io after `epoll-event-loop` and `epoll-event-loop-dogfood` are archived, never on `main`. Do not push, tag or publish without the owner's approval. Run `goose format` on every file you touch. Every step lands with its tests and its documents. Coordinate with `add-stream-extras`: whichever lands second rebases its delta specs onto the other.

## 1. Declarations in the contract

- [ ] 1.1 Add `Supplied`, `Absent`, and for each of the eleven capabilities a default `supplies_<c><Io>(io: Io&) -> Absent` and a query `has_<c><Io>(io: Io&)` (design D2) to `goose_io.goose`. Raise the minor version by one. Verify `goose check goose_io.goose` passes.
- [ ] 1.2 Add `tests/unit/capabilities_test.goose` (renamed from `tests/unit/groups_test.goose`, keeping its checks). It asks each query of the in-memory loop (every capability `Supplied`), of `core_only::Core` (every capability `Absent`; it refuses `unix:`), and of a loop declared in a third namespace. Verify it fails before 1.3 and passes after.
- [ ] 1.3 Declare every capability the in-memory loop supplies in `memory.goose`, and the ones `tests/support/core_only.goose` supplies. Forward the declarations in `tests/support/wrapper.goose` and `tests/support/kit.goose` through `goose_io::has_<c>` (D5). Verify `bash tests/run_tests.sh` passes.

## 2. Checks require the declaration

- [ ] 2.1 Make each `require_<c>` also call `_is_supplied(io.supplies_<c>())` (D4). Verify a new must-fail test, `tests/unit/undeclared_relay_mustfail.goose` (a loop with every relay operation and no declaration), fails to build with an error naming `supplies_relay`. Verify a second must-fail test, `tests/unit/declared_without_ops_mustfail.goose` (declares relay, lacks `relayed_bytes`), fails naming `relayed_bytes`.
- [ ] 2.2 Make the suite's entry point for each capability call `require_<c>`, so it needs the declaration. Verify `bash tests/conformance/run.sh`, `--core-only` and `--wrapped` all pass, and that a must-fail root passing an undeclared peek loop to the peek entry point fails naming `supplies_peek`.

## 3. The rename

- [ ] 3.1 Rename the suite's identifiers (D7) in `conformance/*.goose`, `tests/conformance/*.goose` and `tests/support/*.goose`. Verify `bash tests/run_tests.sh` and every `tests/conformance/run.sh` mode pass.
- [ ] 3.2 Rename the `group` column of `tests/conformance/checks.tsv` to `capability`. Rename `tests/conformance/groups_check.sh` to `capabilities_check.sh`, and update `table_check.sh`, `faults.sh` and `run.sh` to read the new column. Rename `check_group` in `tests/checks/event_loops.sh`. Verify all four scripts pass.
- [ ] 3.3 Restate "group" as "capability" in `goose_io.goose` comments, `README.md`, `CONTRIBUTING.md`, `docs/contract.md`, `docs/libraries.md`, `docs/event-loops.md`, `docs/event-loops/*.md` and `examples/README.md`. In `docs/event-loops.md`, show the exact declaration line a loop adds and the wrapper's forwarding line. Verify `bash tests/checks/docs.sh` passes.
- [ ] 3.4 Extend `tests/checks/vocabulary.sh` to fail on the whole word "group"/"groups" outside the allow-list of D1. Verify it passes, and fails on a scratch file that says "the relay group".
- [ ] 3.5 Update the CI workflow's step names and the renamed script (`.github/workflows/ci.yml`). Leave the `concurrency.group` key alone. Verify every `run:` command exits 0 locally.

## 4. Optional use

- [ ] 4.1 Extend `tests/examples/needs_check.sh` to read `// Uses if supplied:`. Every operation of a capability that is not under `Needs:` must be named under `Uses if supplied:`, and the file must call `goose_io::has_<c>`. Extend its operation list to every capability with operations, not just the first four. Verify it passes on today's examples, and fails on a scratch library that calls `relay` with no header line.
- [ ] 4.2 Write `examples/forward/forward.goose` (D3, D6) with a `// doc:begin`/`// doc:end` excerpt of the branch, so documents can quote it. Verify `goose check` passes for a root over the in-memory loop and for one over `core_only::Core`.
- [ ] 4.3 Write `tests/examples/forward_test.goose`, run on both loops: bytes intact and in order both ways, a client close reaches the backend, a backend close reaches the client, and `Data` is seen by the library only on the core-only loop. Verify both runs pass in fifty repetitions. Add it to `tests/run_tests.sh` and to `examples/README.md`.
- [ ] 4.4 Add "Using a capability when the loop has it" to `docs/libraries.md`, quoting the forward excerpt, and say when to require instead (the library cannot work without it). Verify `bash tests/checks/docs.sh` passes.

## 5. Other specs, loops and acceptance

- [ ] 5.1 Restate "its five groups" in `openspec/specs/epoll-event-loop/spec.md` (archived from `epoll-event-loop`) as "its five capabilities", through a delta in this change if the spec exists when this change is applied. Verify `openspec validate rename-groups-to-capabilities --strict` passes.
- [ ] 5.2 Search `goose-io-epoll-ext` and the epoll loop for the renamed identifiers (`*Group`, `GROUP_*`), and write the declaration lines each needs into a note in `docs/event-loops/` for their owners. Verify the note names every capability each loop's README says it passes.
- [ ] 5.3 Add an entry to `docs/history.md` (groups became capabilities, declarations, optional use). Do a full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow. Verify all exit 0.

## Workflow follow-up

- Merge, push and tag only with the owner's approval.
- Ask the owners of `goose-io-epoll-ext` and the epoll loop to add the declaration lines.
- Archive this change once merged.
