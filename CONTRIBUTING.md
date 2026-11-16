# Contributing

The contract is more important than any one event loop. A change to it needs its reason, a scenario in the
specification (`openspec/`), a check in the conformance suite that proves it, and a fault in the in-memory event loop
that makes that check fail. A change to an event loop must leave the suite passing.

Before sending a change run what CI runs:

```bash
goose check goose_io.goose
goose format --check .
tests/run_tests.sh
tests/checks/docs.sh
tests/conformance/run.sh
tests/conformance/run.sh --wrapped
tests/conformance/run.sh --core-only
tests/conformance/faults.sh
tests/conformance/table_check.sh
tests/conformance/groups_check.sh
tests/examples/over_wrapper.sh
tests/examples/imports_test.sh
tests/examples/needs_check.sh
tests/checks/event_loops.sh
tests/checks/layout.sh
tests/checks/vocabulary.sh
```

Write the test before the code it tests, and run it against the old code to see it fail. A test that fails once in
any repetition is a failure until its cause is explained.

Adding an event loop (it lives in its own repository or under `examples/loops/`):

1. Supply the core, and then any groups you want (`docs/contract.md`, section 2). Call `goose_io::require_core` and the
   check of each group you supply from its root program: a missing operation is then a compile error in one place.
2. Run the core of the conformance suite against it, and each group it supplies (`docs/event-loops.md`), on the operating
   system it targets. An event loop with only the core is complete: leave the groups out until a library needs them.
3. Record the contract version, the core and groups it supplies, and the commit at which it passed, and only then list it
   as conforming.
4. If a backend cannot meet a requirement, record what was tried before proposing a change to the contract.

The words are "event loop" (what supplies the operations), "library" (what handles events) and "application" (what runs
the loop); `tests/checks/vocabulary.sh` fails on the old ones.

The package stays pure Goose: no C, no `extern`, no build sidecar outside `examples/loops/`
(`tests/checks/purity.sh`). Do not add HTTP, TLS, SQL, Redis, pooling, routing or health-check policy to the contract.
