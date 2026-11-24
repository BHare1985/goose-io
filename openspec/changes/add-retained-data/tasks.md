# Tasks

Ground rules: work on a branch of goose-io after `rename-groups-to-capabilities` and `document-capabilities` are applied and accepted, never on `main`. Do not push, tag or publish without the owner's approval. Run `goose format` on every Goose file you touch. Every step lands with its tests and its documents.

## 1. The contract

- [ ] 1.1 Add the handle `Retained` and the five operations to `goose_io.goose`, with comments stating each rule in the contract's words. Verify `goose check goose_io.goose` passes.
- [ ] 1.2 Add the default declaration `supplies_retained_data`, the query `has_retained_data`, and `require_retained_data` naming `retain`, `retained_bytes`, `send_retained`, `release` and `max_retained` and requiring the declaration, with the comment above it that lists the capability's operations and events (the page check reads it). Raise the minor version by one. Verify `goose check` passes.
- [ ] 1.3 Add must-fail tests: `tests/unit/retained_data_undeclared_mustfail.goose` (every operation, no declaration) fails naming `supplies_retained_data`, and `tests/unit/retained_data_missing_op_mustfail.goose` (declared, one operation missing) fails naming it. Extend `tests/unit/capabilities_test.goose` so the in-memory loop answers `Supplied` and the core-only loop `Absent`. Verify all three behave as stated.

## 2. In-memory loop and suite

- [ ] 2.1 Implement retained-data in `memory.goose` (a bounded store of retained ranges with generation-checked handles; `retain` outside a `Data` handler returns an invalid handle; `max_retained` from configuration) and declare it. Forward the declaration in `tests/support/wrapper.goose` and `tests/support/kit.goose`. Verify `bash tests/run_tests.sh` passes.
- [ ] 2.2 Add the retained-data entry point to `conformance/`, with one check for every scenario of the `io-contract` delta of this change, each naming its requirement. Add rows to `tests/conformance/checks.tsv` with capability `retained-data`. Verify `bash tests/conformance/run.sh` passes, that `--core-only` skips the entry point, and that `--wrapped` passes it.
- [ ] 2.3 Add a named fault in the in-memory loop for every new check, and add them to the fault script. Verify `bash tests/conformance/faults.sh` shows each check failing on its own fault, and `table_check.sh` and `capabilities_check.sh` pass.

## 3. Example and documentation

- [ ] 3.1 Write `examples/capabilities/frame_reassembly.goose` (a length-prefixed frame reader that retains partial frames, sends complete ones on with `send_retained`, and copies on a loop without the capability) with a `// Needs:` or `// Uses if supplied:` header and `// doc:begin`/`// doc:end` markers, and `tests/examples/capabilities/frame_reassembly_test.goose`. Verify `goose check` passes, the test passes fifty times in a row, and `tests/examples/needs_check.sh` passes.
- [ ] 3.2 Write `docs/capabilities/retained-data.md` with the sections of design D6, add its row to `docs/capabilities/README.md`, and add the retained-data section to `docs/contract.md` linking to the page. Verify `bash tests/checks/capability_pages.sh` and `bash tests/checks/docs.sh` pass.
- [ ] 3.3 Add a retained-data row to each mapping document in `docs/event-loops/` (io_uring provided buffer rings, DPDK mbuf references, a copy into a loop-owned store elsewhere), and list retained-data as not supplied in every loop's documentation that does not supply it. Verify `bash tests/checks/event_loops.sh` passes.

## 4. Acceptance

- [ ] 4.1 Add an entry to `docs/history.md`. Add every new test to `tests/run_tests.sh` and every new check script step to `.github/workflows/ci.yml`. Verify every `run:` command exits 0 locally.
- [ ] 4.2 Do a full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md`, the three modes of `tests/conformance/run.sh`, and `openspec validate add-retained-data --strict`. Verify all exit 0.

## Workflow follow-up

- Merge, push and tag only with the owner's approval.

- Archive this change once merged.
