# Tasks

Ground rules as in `scoped-library-views`. Apply after it.

## 1. Limits and counters

- [ ] 1.1 Write `tests/unit/limits_test.goose` first: adding a library with no limits fails to compile (a `*_mustfail` test); with limits, the counters start at zero and `unbounded()` never refuses; verify it fails
- [ ] 1.2 Add `Limits`, `unbounded()` and the per-library counters to `scope.goose` and make `add_library` take them; verify 1.1 passes

## 2. Enforcing the limits

- [ ] 2.1 Write the tests first, in `tests/unit/view_limits_test.goose`: the dial limit (first 8 valid, the rest invalid, another library unaffected), the listener limit (`NoResources`, the first two keep accepting), the accepted-link flood (the library sees 8, the registry closes 92, the count is 92), and the `tick_by` clamp (a library asking for a wake-up at once, every Tick, is woken once in the interval and another library's timer is on time); verify they fail
- [ ] 2.2 Enforce the dial and listener limits in the view and the link limit in `route` (which takes the loop and closes an over-limit accepted link); verify the first three tests pass
- [ ] 2.3 Clamp `tick_by` in the view and count the moved requests; verify the fourth test passes and that the virtual clock advances under the flood of 2.1

## 3. The contract

- [ ] 3.1 Amend the finished-loop requirement and add *A layer may refuse a dial* in `docs/contract.md` and `docs/libraries.md` (check `is_valid` on the link `dial` returns); verify `tests/checks/docs.sh` passes
- [ ] 3.2 Check that each example library tests `is_valid` on the link `dial` returns, and add the test where one does not; verify `tests/run_tests.sh` passes

## 4. Example and documents

- [ ] 4.1 Add a flooding library to `examples/scoped.goose` and its test: it dials without end and listens on many addresses, and the others keep working; verify it passes and that without limits the same library takes every link
- [ ] 4.2 In `docs/libraries.md`, "Isolating libraries", add limits and the counters, and the cost; verify `docs.sh` passes

## 5. Everything together

- [ ] 5.1 Run every command of `CONTRIBUTING.md`; verify they pass
- [ ] 5.2 Run `openspec validate library-resource-limits --strict`; verify it is valid and every scenario is named by a test
