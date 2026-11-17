# Tasks

Ground rules as in `scoped-library-views`. Independent of the view proposals.

## 1. Conformance for the path

- [ ] 1.1 Write the cases first in `conformance/` and `tests/conformance/checks.tsv`: listening on a taken path fails with `AddressInUse` and the first listener keeps accepting; the path is free after `stop_listening`; the path is free after `serve` returns; a failed `listen` removes nothing; verify they fail against the current `memory.goose`
- [ ] 1.2 Add one fault to `tests/conformance/faults.sh` for each case (replaces the path, keeps it after stop, keeps it after finish, removes a file it did not create) and check each is caught; verify the table check passes
- [ ] 1.3 Make `memory.goose` meet the cases; verify 1.1 passes and the faults are caught

## 2. Documents

- [ ] 2.1 Add the three requirements to the unix group in `docs/contract.md`, with the default mode and what the contract leaves to the loop; verify `docs.sh` passes
- [ ] 2.2 Add a "Unix" section to each `docs/event-loops/*.md` stating how the loop meets the requirements, or that it has no unix group; add the section to the checked list in `tests/checks/event_loops.sh`; verify the check passes
- [ ] 2.3 In `docs/libraries.md`, say that a stale socket file is the application's to remove; verify `docs.sh` passes

## 3. Everything together

- [ ] 3.1 Run every command of `CONTRIBUTING.md`; verify they pass
- [ ] 3.2 Run `openspec validate unix-socket-permissions --strict`; verify it is valid and every scenario is named by a check
