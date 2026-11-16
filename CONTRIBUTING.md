# Contributing

The contract is more important than any one provider. A change to it needs its reason, a scenario in the
specification (`openspec/`), a check in the conformance suite that proves it, and a fault in the in-memory provider
that makes that check fail. A change to a provider must leave the suite passing.

Before sending a change run what CI runs:

```bash
goose check goose_io.goose
goose format --check .
tests/run_tests.sh
tests/checks/docs.sh
tests/conformance/run.sh
tests/conformance/run.sh --wrapped
tests/conformance/faults.sh
tests/conformance/table_check.sh
tests/examples/over_wrapper.sh
tests/examples/imports_test.sh
tests/checks/providers.sh
tests/checks/layout.sh
```

Write the test before the code it tests, and run it against the old code to see it fail. A test that fails once in
any repetition is a failure until its cause is explained.

Adding a provider (it lives in its own repository or under `examples/providers/`):

1. Call `goose_io::require_provider` from its root program: a missing operation is then a compile error in one place.
2. Run every part of the conformance suite against it (`docs/providers.md`), on the operating system it targets.
3. Record the contract version and the commit at which it passed, and only then list it as conforming.
4. If a backend cannot meet a requirement, record what was tried before proposing a change to the contract.

The package stays pure Goose: no C, no `extern`, no build sidecar outside `examples/providers/`
(`tests/checks/purity.sh`). Do not add HTTP, TLS, SQL, Redis, pooling, routing or health-check policy to the contract.
