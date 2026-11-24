# Tasks

Ground rules: work on a branch of goose-io after `rename-groups-to-capabilities` and `document-capabilities` are applied and accepted, never on `main`. Do not push, tag or publish without the owner's approval. Run `goose format` on every Goose file you touch. Every step lands with its tests and its documents.

## 1. The contract

- [ ] 1.1 Add the listen error kind `NotInherited` and the two operations to `goose_io.goose`, with comments stating each rule in the contract's words. Verify `goose check goose_io.goose` passes.
- [ ] 1.2 Add the default declaration `supplies_listener_inheritance`, the query `has_listener_inheritance`, and `require_listener_inheritance` naming `adopt_listener` and `export_listeners` and requiring the declaration, with the comment above it that lists the capability's operations and events (the page check reads it). Raise the minor version by one. Verify `goose check` passes.
- [ ] 1.3 Add must-fail tests: `tests/unit/listener_inheritance_undeclared_mustfail.goose` (every operation, no declaration) fails naming `supplies_listener_inheritance`, and `tests/unit/listener_inheritance_missing_op_mustfail.goose` (declared, one operation missing) fails naming it. Extend `tests/unit/capabilities_test.goose` so the in-memory loop answers `Supplied` and the core-only loop `Absent`. Verify all three behave as stated.

## 2. In-memory loop and suite

- [ ] 2.1 Implement listener-inheritance in `memory.goose` (a process-wide table keyed by the hand-over path; exported listeners keep their queued connections; a loop configured with the path offers them to `adopt_listener`) and declare it. Forward the declaration in `tests/support/wrapper.goose` and `tests/support/kit.goose`. Verify `bash tests/run_tests.sh` passes.
- [ ] 2.2 Add the listener-inheritance entry point to `conformance/`, with one check for every scenario of the `io-contract` delta of this change, each naming its requirement. Add rows to `tests/conformance/checks.tsv` with capability `listener-inheritance`. Verify `bash tests/conformance/run.sh` passes, that `--core-only` skips the entry point, and that `--wrapped` passes it.
- [ ] 2.3 Add a named fault in the in-memory loop for every new check, and add them to the fault script. Verify `bash tests/conformance/faults.sh` shows each check failing on its own fault, and `table_check.sh` and `capabilities_check.sh` pass.

## 3. Example and documentation

- [ ] 3.1 Write `examples/capabilities/graceful_restart.goose` (an old server that exports its listener and drains its links, and a new one that adopts it, with a client that connects throughout and is never refused) with a `// Needs:` or `// Uses if supplied:` header and `// doc:begin`/`// doc:end` markers, and `tests/examples/capabilities/graceful_restart_test.goose`. Verify `goose check` passes, the test passes fifty times in a row, and `tests/examples/needs_check.sh` passes.
- [ ] 3.2 Write `docs/capabilities/listener-inheritance.md` with the sections of design D6, add its row to `docs/capabilities/README.md`, and add the listener-inheritance section to `docs/contract.md` linking to the page. Verify `bash tests/checks/capability_pages.sh` and `bash tests/checks/docs.sh` pass.
- [ ] 3.3 Add a listener-inheritance row to each mapping document in `docs/event-loops/` (`LISTEN_FDS`/`LISTEN_FDNAMES` from systemd and `SCM_RIGHTS` over a unix socket on Linux and the BSDs; a process-wide table between in-memory loops), and list listener-inheritance as not supplied in every loop's documentation that does not supply it. Verify `bash tests/checks/event_loops.sh` passes.

## 4. Acceptance

- [ ] 4.1 Add an entry to `docs/history.md`. Add every new test to `tests/run_tests.sh` and every new check script step to `.github/workflows/ci.yml`. Verify every `run:` command exits 0 locally.
- [ ] 4.2 Do a full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md`, the three modes of `tests/conformance/run.sh`, and `openspec validate add-listener-inheritance --strict`. Verify all exit 0.

## Workflow follow-up

- Merge, push and tag only with the owner's approval.

- Archive this change once merged.
