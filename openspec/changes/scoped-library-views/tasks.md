# Tasks

Ground rules: work on a branch, not `main`; write the test before the code it tests and see it fail; a test that fails once in any repetition is a failure until explained; nothing here adds C or an `extern`; use the contract's words (`tests/checks/vocabulary.sh`); run `goose check` after every edit. Apply after `security-model`.

## 1. Library operations and application operations

- [ ] 1.1 Write `tests/unit/require_library_test.goose` and `tests/unit/require_library_mustfail.goose` first: a type with every core operation but `serve` and `stop` compiles under `require_library`, and one without `send` fails naming `send`; verify they fail because `require_library` does not exist
- [ ] 1.2 Add `require_library` to `goose_io.goose`, naming the ten library operations with the contract's types; verify `goose check goose_io.goose` is clean and the tests of 1.1 pass
- [ ] 1.3 In `docs/contract.md` (section 2 and the operations table) mark each operation as a library or an application operation; verify `tests/checks/docs.sh` passes

## 2. The registry

- [ ] 2.1 Write `tests/unit/registry_test.goose` first for: a link recorded at `dial` is owned by that library; an accepted link is owned by its listener's owner when routed; `route` names `TICK` for a `Tick`; a `Closed` drops the entry after `done`; a link with no owner and an unregistered listener route to `-1`; a reused slot carries the new owner; verify it fails because `scope.goose` does not exist
- [ ] 2.2 Create `scope.goose` (namespace `goose_io_scope`) with `Registry` (a `LinkMap<Owner>`, the listener owners indexed by id, the library count), `add_library`, `route` and `done`; verify 2.1 passes and `goose check scope.goose` is clean

## 3. The view

- [ ] 3.1 Write `tests/unit/view_matrix_test.goose` first: for every library operation, the five handles of design D9 (owned, another's, stale, never issued, invalid) and a guessed range, with the results of D5; also that a view's `dial` and `listen` record ownership; verify it fails
- [ ] 3.2 Add `View<Io>` and its operations to `scope.goose`: the ten library operations and, as functions that compile only when called, each group operation; `now_ms`, `max_send` and `draining` pass through; verify 3.1 passes
- [ ] 3.3 Write `tests/unit/view_stop_mustfail.goose`: a library that calls `stop` on a view fails to compile naming `stop`; verify it passes
- [ ] 3.4 Add `tests/checks/view_ops.sh`: every operation named in the contract's `require_*` checks has a function in `scope.goose`; verify it passes, and fails when one is removed, and add it to `tests/run_tests.sh` and the `Justfile`

## 4. Libraries run unchanged through views

- [ ] 4.1 Add `tests/examples/scoped_libraries_test.goose`: the echo test, the line server tests, the line client tests and the gateway test each run once through views, with the libraries unchanged; verify they pass and that no library file under `examples/` changed
- [ ] 4.2 Write `examples/scoped.goose` (an application with an echo server, a line client and a hostile library, each on its own view) and `tests/examples/scoped_test.goose`: the hostile library's `send`, `close` and `pause_reading` on the others' links return `Closed` or do nothing, it is never called for their events, and it cannot call `stop`; verify it passes, and that without views the same attack succeeds (so the test is not vacuous)
- [ ] 4.3 Add `examples/scoped.goose` to `tests/examples/needs_check.sh` and the layout list in `CONTRIBUTING.md`; verify the checks pass

## 5. Cost

- [ ] 5.1 Add benchmark arms for offering in turn, routing by link and a view plus the registry, for 2, 10 and 100 libraries, to `bench/`; run three times pinned to one core; verify the figures agree within noise
- [ ] 5.2 Record the result in `bench/README.md` with the machine, compiler version and date, and state the cost of an operation through a view and of routing an event; verify `tests/checks/layout.sh` passes

## 6. Documents

- [ ] 6.1 In `docs/contract.md` section 7 add "Views" (what a view guarantees, the table of D5, what it does not protect), and in `docs/libraries.md` add "Isolating libraries" with the example quoted from `examples/scoped.goose`; verify `tests/checks/docs.sh` passes
- [ ] 6.2 In `README.md` say in one place that an application can give each library its own view, and link `docs/security.md` once it exists; verify the vocabulary and layout checks pass

## 7. Everything together

- [ ] 7.1 Run every command of `CONTRIBUTING.md` and `tests/conformance/run.sh --repeat 20`; verify they pass and the output of each repetition is identical
- [ ] 7.2 Run `openspec validate scoped-library-views --strict`; verify it is valid and that every scenario of both spec files is named by a test
