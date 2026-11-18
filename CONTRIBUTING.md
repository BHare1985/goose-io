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

The epoll event loops live in their own repositories ([goose-io-epoll](https://github.com/BHare1985/goose-io-epoll), [goose-io-epoll-ext](https://github.com/BHare1985/goose-io-epoll-ext)), which test themselves against this package.

A change to that loop also holds the gates of `bench/` (`gate_syscalls.sh`, `gate_http.sh`, `gate_memory.sh`, `gate_forward.sh`; they need
`strace`, `wrk` and an idle host, and are not run by CI).

Write the test before the code it tests, and run it against the old code to see it fail. A test that fails once in
any repetition is a failure until its cause is explained.

Adding an event loop (it lives in its own repository):

1. Supply the core, and then any groups you want (`docs/contract.md`, section 2). Call `goose_io::require_core` and the
   check of each group you supply from its root program: a missing operation is then a compile error in one place.
2. Run the core of the conformance suite against it, and each group it supplies (`docs/event-loops.md`), on the operating
   system it targets. An event loop with only the core is complete: leave the groups out until a library needs them.
3. Record the contract version, the core and groups it supplies, and the commit at which it passed, and only then list it
   as conforming.
4. If a backend cannot meet a requirement, record what was tried before proposing a change to the contract.

The words are "event loop" (what supplies the operations), "library" (what handles events) and "application" (what runs
the loop); `tests/checks/vocabulary.sh` fails on the old ones.

The package stays pure Goose: no C, no `extern`, no build sidecar
(`tests/checks/purity.sh`). Do not add HTTP, TLS, SQL, Redis, pooling, routing or health-check policy to the contract.

## Repository layout

- `goose_io.goose`: the contract: the types, the helpers, the version and `require_core` with one check for each group
- `bench/`: micro-benchmarks and the performance gates of the epoll event loop, built and run by hand; `README.md` indexes them and holds their results (`link_map_bench.goose`: what a table keyed by link costs); `BASELINE.md` says what the gates compare against, `results/` keeps their tables, the loop with forwarding added back is `examples/loops/forward_ext/`
- `deadlines.goose`: `Deadlines`, a bounded heap of deadlines for libraries that have many
- `memory.goose`: the in-memory event loop, with scripted peers, a virtual clock and the named faults
- `conformance/`: the conformance suite, which imports only the contract: `suite.goose` is the driver and the entry points, `support.goose` what every check shares, `handles`, `net`, `data`, `close` and `time` the checks
- `examples/`: the example libraries: `echo/`, `lineserver/`, `lineclient/` and `gateway.goose`, which runs the last two on one loop, and `dispatch.goose`, which sends each event to the library that owns its link
- `docs/`: `contract.md`, `libraries.md`, `event-loops.md` and `history.md`
- `docs/event-loops/`: how each candidate event loop maps onto the contract
- `tests/unit/`: tests of the types, `Deadlines` and the in-memory event loop
- `tests/examples/`: tests of the example libraries, and the scripts that run them over the wrapper
- `tests/conformance/`: running the suite (`run.sh`, `faults.sh`, `table_check.sh`, `groups_check.sh`), the table of checks and faults (`checks.tsv`), and the driver's own tests
- `docs/tcprouter-adoption.md`: where tcprouter's engine went in the epoll event loop and what its refactor has to hold
- `tests/support/`: what tests share: `kit.goose` (the test kit), `wrapper.goose` (an event loop layered over another), `core_only.goose` (an event loop that supplies only the core) and `stub.goose`
- `tests/checks/`: scripts that check the repository itself: quoted code, purity, vocabulary, event loop mappings, this layout
- `tests/run_tests.sh`: runs every `*_test.goose` and `*_mustfail.goose`, the purity check and the vocabulary check
- `openspec/`: the specification and the changes that made it
- `Justfile`: `just check`, `just test`, `just fmt`
- `CONTRIBUTING.md`: what to run before sending a change, and how to add an event loop
- `README.md`: the front door: what goose-io is, where it stands, where to start
- `LICENSE`: Apache-2.0
