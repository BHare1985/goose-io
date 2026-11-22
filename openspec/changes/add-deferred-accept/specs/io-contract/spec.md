## ADDED Requirements

### Requirement: The deferred accept capability is named by its parts
The contract SHALL have an optional capability named deferred-accept, made of the operation `defer_accept(listener, ms) -> bool`. It SHALL have the declaration `supplies_deferred_accept`, the query `has_deferred_accept` and the compile-time check `require_deferred_accept`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `defer_accept` without a compile-time branch is built against an event loop that does not declare deferred-accept
- **THEN** the build fails and the error names `supplies_deferred_accept` or `defer_accept`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `defer_accept` only in the branch taken when `goose_io::has_deferred_accept` is `Supplied` is built against the core-only loop
- **THEN** it builds, and every link is opened when it connects, as today

### Requirement: A deferring listener opens a link when its first bytes arrive
After `defer_accept(listener, ms)` with `ms` above 0, the loop SHALL deliver the `Opened` of a link that listener accepts in the pass in which the link's first bytes arrive, followed in that pass by a `Data` of them, and not before. `ms` 0 SHALL turn deferring off. It SHALL return whether the loop applied it.

#### Scenario: A client that speaks
- **WHEN** a client connects to a deferring listener and sends a request after 20 ms
- **THEN** the server sees `Opened` and the request's `Data` in one pass, 20 ms after the connect

### Requirement: A deferred link opens at the time
A link that sends nothing SHALL get its `Opened`, with no `Data`, in the first pass at or after `ms` since it connected, measured on `now_ms`. A connection that ends before its `Opened` is delivered SHALL be dropped and never seen by the library.

#### Scenario: A client that stays silent
- **WHEN** a client connects to a listener deferring 1000 ms and sends nothing
- **THEN** the server sees `Opened` at 1000 ms and no `Data`

#### Scenario: A client that leaves
- **WHEN** a client connects to a deferring listener and closes before sending
- **THEN** the server library sees neither `Opened` nor `Closed` for it
