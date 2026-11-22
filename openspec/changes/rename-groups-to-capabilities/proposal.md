# Proposal

## Why

The contract calls its optional parts "groups of extras", which says how they are packaged and not what they give. Each one is a capability that only some event loops have: relay, peek, wake and the rest. A library today can only require a group. Its header says `// Needs: core and relay`, and the build fails on a loop without relay. A library cannot say "use relay when the loop has it and copy the bytes when it does not." So a proxy that would gain from relay must either demand it, and lose every loop without it, or never use it. The nine groups still to come (`add-stream-extras`, then the advanced capabilities) make this worse. Most of them make an existing behaviour faster, so a library will want them optionally.

## What Changes

- **Vocabulary:** "group" becomes "capability" everywhere the contract, the specs, the documents, the suite and the tests use it. The core is still the core. "The core and the capabilities" replaces "the core and groups of extras". The names of the eleven capabilities (half-close, sizing, abort, inspection, batching, unix, relay, peek, revoke, wake, limits) do not change.
- **Declarations:** every capability gets a compile-time declaration. A loop that supplies relay says so with `fn supplies_relay(io: Loop&) -> goose_io::Supplied`. The contract answers `goose_io::Absent` for every loop that does not. `goose_io::has_relay(io)` is the query that libraries and wrapper loops call. Batching and unix, which have no operations, get a declaration too. A loop whose declaration says `Supplied` but which lacks an operation fails to build, and the error names the operation.
- **Optional use:** a library may now use a capability optionally. It branches at compile time with `const if same<S, goose_io::Supplied>`, so the branch for a missing capability is never type-checked. Its header names what it needs (`// Needs:`) and, on a new line, what it uses when the loop supplies it (`// Uses if supplied:`). A library that uses a capability optionally builds on a loop without it and takes its other path.
- **Required stays as it is:** `require_<capability>` keeps its name and meaning. It now also requires the loop's declaration to say `Supplied`.
- **Identifiers** in the suite and the tests follow the new word. `CoreGroup`/`RelayGroup` become `CoreSuite`/`RelaySuite`, `GROUP_*` becomes `CAPABILITY_*`, and the `group` column of `tests/conformance/checks.tsv` becomes `capability`. `groups_check.sh` becomes `capabilities_check.sh`, `tests/unit/groups_test.goose` becomes `tests/unit/capabilities_test.goose`, and `check_group` in `tests/checks/event_loops.sh` becomes `check_capability`.
- `tests/checks/vocabulary.sh` fails when the contract's old word "group" comes back, as it does for "provider".
- **BREAKING (compile time only):** a loop outside this repository that supplies a capability must add the one-line declaration before `require_<capability>` builds against it. A library that calls only `require_*` and the operations does not change. The contract version goes up one minor step.
- A new example library, `examples/forward/forward.goose`, shows optional use. It forwards each accepted link to a backend: it relays when the loop supplies relay and copies with `send` and `pause_reading` when it does not. It is tested on the in-memory loop and on the core-only loop.

Out of scope: new capabilities, documentation pages per capability (`document-capabilities`), the capabilities of `add-stream-extras` (that change adopts the new word and the declarations), and run-time negotiation. Supplying a capability stays a fact about the loop's type, never about a value.

## Capabilities

### New Capabilities

None. (OpenSpec's own "capability" is a spec area, such as `io-contract`. This change does not add one.)

### Modified Capabilities

- `io-contract`: every requirement that says "group" is restated with "capability". The requirement that splits the contract into a core and its parts, and the one that names and checks them, now cover declarations and optional use. New requirements cover the declaration, optional use by a library, and a declaration that disagrees with the operations.
- `provider-conformance`: every requirement that says "group" is restated with "capability". The suite's entry point for a capability requires the loop's declaration. The documentation of a loop lists the capabilities its declarations name.

## Impact

- **Code:** `goose_io.goose` (`Supplied`, `Absent`, a `supplies_<c>` default and a `has_<c>` query for each of the eleven, `require_*` checking the declaration, the version, the header comment), `memory.goose`, `tests/support/core_only.goose`, `tests/support/wrapper.goose`, `tests/support/kit.goose` (declarations and forwarding), `conformance/*.goose` (identifiers), `tests/conformance/*` (table column, scripts renamed), `tests/unit/*` (renamed test, new must-fail tests for a lying declaration, an optional-use test), `tests/examples/needs_check.sh` (the second header line), `tests/checks/vocabulary.sh`, `tests/checks/event_loops.sh`, `.github/workflows/ci.yml` (step names and the renamed script), `examples/forward/forward.goose` (new) and its tests.
- **Documents:** `README.md`, `CONTRIBUTING.md`, `docs/contract.md`, `docs/libraries.md`, `docs/event-loops.md`, `docs/event-loops/*.md`, `examples/README.md`. `docs/history.md` and the archived changes keep the old word, because they record what was true then.
- **Other changes:** `add-stream-extras` adopts the word and the declarations (it is updated alongside this change). The `epoll-event-loop` spec ("its five groups") is restated once that change is archived, by a task of this change.
- **Event loops outside the repository** (`goose-io-epoll-ext`, the epoll loop): each adds a declaration for every capability it supplies.
- **Toolchain:** Goose v2026.4. `const if` and the overload resolution this relies on were tried on that version (design D2).
