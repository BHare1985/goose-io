# Proposal

## Why

An application runs several libraries on one event loop and gives each of them the same loop. The loop cannot tell which library is calling, so nothing separates one library from another:

- A library can `send`, `close` or `reset` any link whose handle it has seen. A handle is a slot and a generation, so it can also be guessed; the generation only stops a *stale* handle from reaching a reused slot.
- When the application offers each event to the libraries in turn, a library is offered, and so sees the bytes of, events for links that are not its own. Nothing enforces that it ignores them.
- A library can claim an event that is not its own, or call `stop` and end the loop for everyone.
- The application cannot learn the owner of a link that a library dials for itself, because it never sees the handle `dial` returned. Direct dispatch (`examples/dispatch.goose`) has to learn owners from the libraries' own claims.

The tag the contract used to carry had the same weakness and was worse: a library passed the tag itself, so it could create links that were routed to another library. The contract is a cooperation contract, and that is right for libraries from one author. An application that composes libraries from different authors wants the boundary enforced, without a change to any library or any event loop.

## What Changes

- Add a **view**: a small wrapper that gives one library its own `io`. It presents the contract's library operations over the shared event loop and records, from provenance, which library made each link and listener. An operation on a link or listener that the library does not own behaves as on an invalid handle.
- Add a **registry**: the one table that the views share (link to owner, listener to owner). The application asks it which library an event is for, and calls only that library.
- Split the contract's operations into **library operations** and **application operations**. `serve` and `stop` are the application's; a view supplies neither, so a library that calls `stop` fails to compile. A new compile-time check, `require_library`, names the library operations.
- Add the hostile-library tests that show what a view stops, run the example libraries unchanged through views, and record the cost of a view and of the registry in `bench/`.
- Document the trust boundary this gives (contract section 7, `docs/libraries.md`, the README): mediation inside one process, not a sandbox.

Out of scope: process isolation and anything that stops a library from reading memory (Goose has no in-process sandbox); quotas (`library-resource-limits`); address policy (`library-address-policy`); removing a library at run time; any change to an event loop or to a library.

## Capabilities

### New Capabilities

- `library-views`: a view and a registry that enforce which library owns which link and listener, and deliver an event only to its owner.

### Modified Capabilities

- `io-contract`: adds the distinction between library operations and application operations, and the `require_library` check.

## Impact

- **goose-io:** new `scope.goose` (pure Goose, outside `goose_io.goose` so the contract surface stays small), `require_library` in `goose_io.goose`, `tests/unit/` (the registry, the view, the hostile-library matrix), `examples/scoped.goose` and `tests/examples/scoped_test.goose`, `bench/link_map_bench.goose` or a new benchmark, `tests/checks/view_ops.sh`, `docs/contract.md`, `docs/libraries.md`, `README.md`.
- **Event loops and libraries:** none changes. A library is generic over the loop type, so a view is just another `io`. An application adopts views one library at a time.
- **Version:** additive, so no bump while 0.2 is unreleased.
- **Related proposals:** `security-model` (the threat model that says what this does and does not give), `library-resource-limits` and `library-address-policy` (built on the view).
- **Risk:** the view becomes the trusted piece, so a missing operation or a wrong ownership rule is a hole. `tests/checks/view_ops.sh` fails when a contract operation has no view function.
