# Tasks

Ground rules for every capability: work on a branch of goose-io after `rename-groups-to-capabilities` and `document-capabilities` are applied and accepted, never on `main`; do not push, tag or publish without the owner's approval; write each check before the code it checks and see it fail first; a check that fails once in any repetition is a failure until explained; every scenario of the spec has a check that names it, and every check has a fault; keep the pure-Goose rule. This change touches only the contract, the in-memory loop, the suite and the documents; no real event loop and no tcprouter file.

## 1. The contract package

- [ ] 1.1 Add the handle types `File` and `Loan` to `goose_io.goose` (a slot and a generation, the invalid value reserved, `is_valid` and `same`), and raise the minor version by one; verify `goose check goose_io.goose` passes
- [ ] 1.2 Add `require_files`, `require_loans`, `require_parts` and `require_addresses`, each naming every operation of its capability once with the contract's types; verify each fails to compile on the core-only loop naming its first operation (new `*_mustfail` tests) and passes on the in-memory loop once 2.x lands
- [ ] 1.3 Add `supplies_files`, `supplies_loans`, `supplies_parts` and `supplies_addresses` (the `Absent` default) and `has_files` … `has_addresses`, with the comment above each naming its operations, and make each `require_` check the declaration (design D6). Verify a must-fail loop with every parts operation and no declaration fails `require_parts` naming `supplies_parts`.
- [ ] 1.4 Add the four capabilities to `docs/contract.md`; verify `tests/checks/docs.sh` and `tests/checks/vocabulary.sh` pass

## 2. The in-memory loop and the suite, capability by capability

Each of 2.1 to 2.4 is the same four steps: write the checks of the capability in `conformance/` and add its entry point, see them fail to build against the loop without the capability, add the capability to `memory.goose`, then add one fault for each check and show each check fails against its fault (`tests/conformance/faults.sh`). Every check's name and requirement go in `tests/conformance/checks.tsv`.

- [ ] 2.1 parts: `send_parts` with zero, one and three parts, all-or-nothing, the `Full` and `TooLarge` sums, the list bound; verify the suite's parts entry point passes in fifty repetitions and every fault fails its check
- [ ] 2.2 addresses: `local_address` and `original_destination` for IPv4 and IPv6, a stale link and a `unix:` link, and the in-memory loop's way of scripting a redirection; verify as 2.1
- [ ] 2.3 loans: take, fill, send, refused and kept, released, the bound, a stale handle after `Sent`; verify as 2.1
- [ ] 2.4 files: `open_file` on a file the test registers in memory, `send_file`, a range past the end, a missing file, `close_file` while a send is accepted; verify as 2.1
- [ ] 2.5 Update `tests/conformance/table_check.sh`, `capabilities_check.sh`, `tests/conformance/run.sh` and "Which check proves which scenario" in `docs/event-loops.md` for the new capabilities; verify all pass

## 3. Optional use and pages

- [ ] 3.1 Write `examples/capabilities/static_files.goose` (design D6): `send_file` and `send_parts` when supplied, read and `send` otherwise, with `// Needs: core only.` and `// Uses if supplied: files, parts.`. Write its test in `tests/examples/capabilities/`, run on the in-memory loop and on the core-only loop. Verify both pass in fifty repetitions and `tests/examples/needs_check.sh` passes.
- [ ] 3.2 Write `docs/capabilities/files.md`, `loans.md`, `parts.md` and `addresses.md` with the fixed sections (design D7), each quoting checked code: `static_files.goose` for files and parts, a loan from the loans suite's common-use test, and a small transparent forwarder over the in-memory loop's scripted redirection for addresses. Add their rows to `docs/capabilities/README.md`. Verify `bash tests/checks/capability_pages.sh` and `bash tests/checks/docs.sh` pass.

## 4. Documents and acceptance

- [ ] 4.1 Document each capability in `docs/libraries.md` and `docs/event-loops.md` (what a loop must do to supply it, and the mechanisms it may use), add a row for each capability to the mapping documents of the candidate loops where the mechanism is known, and update `CONTRIBUTING.md`, the layout and the README's list of capabilities; verify `tests/checks/docs.sh`, `layout.sh`, `vocabulary.sh` and `event_loops.sh` pass
- [ ] 4.2 Update the CI workflow (the new capabilities' suites in the existing jobs); verify every `run:` command exits 0 locally
- [ ] 4.3 Full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow, every new capability's suite on the in-memory loop with fifty repetitions, the faults; verify all pass, then `openspec validate add-stream-extras --strict`, and record the commit, Goose version and results in `docs/history.md`

## Workflow follow-up

- Merge, push and tag only with the owner's approval.
- Archive this change once merged.
- Later, separate work: implement the capabilities that have a user on a real loop.
