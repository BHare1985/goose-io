# Tasks

Ground rules: work on a branch of goose-io after `rename-groups-to-capabilities` is applied and accepted, never on `main`. Do not push, tag or publish without the owner's approval. Run `goose format` on every Goose file you touch. Every page lands with its examples and their tests.

## 1. Checks first

- [x] 1.1 Extend `tests/checks/docs.sh` to read `docs/capabilities/*.md`. Verify it passes with the directory empty and fails on a scratch page whose excerpt differs from its file.
- [x] 1.2 Write `tests/checks/capability_pages.sh` (design D4), with must-fail fixtures under `tests/checks/fixtures/capability_pages/`: a missing page, a missing section, a section out of order, an operation left out of "What it is", no checked example, a page missing from the index. Verify each fixture fails with a message naming the page and the problem. Verify the check fails on the repository as it stands, naming all eleven capabilities.
- [x] 1.3 Add both checks to `.github/workflows/ci.yml` (the step stays red until group 3 lands on the branch). Verify the step runs locally.

## 2. Example programs

Each of 2.1 to 2.8 is a small library in `examples/capabilities/` (design D3) with a `// Needs:` header, `// doc:begin`/`// doc:end` markers around the parts a page quotes, and a test in `tests/examples/capabilities/` on the in-memory loop. Verify for each: `goose check` passes, its test passes in fifty repetitions, and `tests/examples/needs_check.sh` passes.

- [ ] 2.1 sizing: `frames.goose`, length-prefixed frames with `send2` and `send_room`.
- [ ] 2.2 abort: `reject.goose`, reset a client whose first line is malformed. Its test sees `PeerReset` at the client.
- [ ] 2.3 inspection: `access_log.goose`, `peer_address` at `Opened`, `stop_listening` when draining.
- [ ] 2.4 batching: `batch_reply.goose`, replies queued in a pass and sent on `PassEnd`. Its test checks that one pass of ten requests gives ten replies after the pass.
- [ ] 2.5 peek: `sniff.goose`, `wait_input` for the first bytes, then serve a greeting itself or relay to a backend.
- [ ] 2.6 revoke: `fenced_writer.goose`, `write_deadline` at a fence and `discard_unsent` on cancel. Its test uses the in-memory clock.
- [ ] 2.7 wake: `worker_reply.goose`, a worker thread replies through `wake_with`. Its test joins the worker.
- [ ] 2.8 limits: `idle_reaper.goose`, `Idle` and `Age` limits on a relayed pair, closing on `Expired`.
- [ ] 2.9 Add `// doc:begin`/`// doc:end` markers to `examples/lineserver/server.goose` (half-close), `tests/examples/unix_dial_test.goose` (unix) and `examples/forward/forward.goose` (relay). Add `examples/capabilities/` and `tests/examples/capabilities/` to `tests/run_tests.sh`. List them in `examples/README.md` as examples, not libraries to depend on. Verify `bash tests/run_tests.sh` passes.

## 3. Pages

Each of 3.1 to 3.11 is one page with the sections of design D2, linking to its `docs/contract.md` section, with its example from group 2 or 2.9 quoted as a checked block. Verify for each: `bash tests/checks/docs.sh` passes, and `bash tests/checks/capability_pages.sh` no longer names it.

- [ ] 3.1 `docs/capabilities/half-close.md`
- [ ] 3.2 `docs/capabilities/sizing.md`
- [ ] 3.3 `docs/capabilities/abort.md`, including the comparison of `shutdown_write`, `close` and `reset`, linked from the contract
- [ ] 3.4 `docs/capabilities/inspection.md`
- [ ] 3.5 `docs/capabilities/batching.md`
- [ ] 3.6 `docs/capabilities/unix.md`, which says why optional use is not worth it (the address is the caller's choice)
- [ ] 3.7 `docs/capabilities/relay.md`, which shows optional use with the forward example
- [ ] 3.8 `docs/capabilities/peek.md`
- [ ] 3.9 `docs/capabilities/revoke.md`
- [ ] 3.10 `docs/capabilities/wake.md`
- [ ] 3.11 `docs/capabilities/limits.md`, moving the library guidance of the "Limits" section of `docs/libraries.md` here and leaving a link
- [ ] 3.12 `docs/capabilities/README.md`: what a capability is, declaring and asking (quoting the rename's declaration line and `has_` query), the table of all eleven. Verify `bash tests/checks/capability_pages.sh` passes.

## 4. Links and acceptance

- [ ] 4.1 Link the index from `README.md` and from "What a library needs" in `docs/libraries.md`, and each page from its section in `docs/contract.md`. Add "Adding a capability" to `CONTRIBUTING.md` (the page, the index row and a checked example in the same change). Verify `bash tests/checks/docs.sh` and `bash tests/checks/vocabulary.sh` pass.
- [ ] 4.2 Add an entry to `docs/history.md`. Do a full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow. Verify all exit 0.

## Workflow follow-up

- Merge, push and tag only with the owner's approval.
- Archive this change once merged.
