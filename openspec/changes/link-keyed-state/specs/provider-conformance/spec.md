# Spec Delta

## MODIFIED Requirements

### Requirement: Listener addresses do not overlap
In the in-memory event loop, `listen` SHALL fail with `AddressInUse` when an active listener or a held address has the same address family and port and either address is the wildcard or the two are equal. A dial SHALL therefore match at most one listener. A stopped listener SHALL NOT conflict, and IPv4 and IPv6 are separate families.

#### Scenario: Wildcard then specific
- **WHEN** a library listens on `0.0.0.0:8080` and then on `127.0.0.1:8080`
- **THEN** the second `listen` returns `AddressInUse` and a dial to `127.0.0.1:8080` opens a link accepted by the first listener

#### Scenario: Specific then wildcard
- **WHEN** a library listens on `127.0.0.1:8080` and then on `0.0.0.0:8080`
- **THEN** the second `listen` returns `AddressInUse`

#### Scenario: A held wildcard
- **WHEN** a test holds `0.0.0.0:8080` and a library listens on `127.0.0.1:8080`
- **THEN** `listen` returns `AddressInUse`

#### Scenario: Different ports, families and stopped listeners
- **WHEN** a library listens on `0.0.0.0:8080`, then on `127.0.0.1:8081` and `[::1]:8080`, and stops the first listener and listens on `127.0.0.1:8080`
- **THEN** every one of those `listen` calls succeeds

## ADDED Requirements

### Requirement: The suite checks how events find their owner
The suite SHALL have a check for each scenario of *A link event is recognised by what the library holds* that is about the event loop (an accepted link names its listener, a dial that fails at once is found by its link), for each scenario of *Slot numbers are dense* and *A slot is freed when its Closed has been handled*, and for the no-event-inside-`dial` scenario of *Dialling never blocks and always ends in one event*, each with a recorded fault of the in-memory event loop.

#### Scenario: A loop that names the wrong listener fails
- **WHEN** the in-memory loop is made to put the first listener's handle on every `Opened`
- **THEN** the check that an accepted link names its listener fails

#### Scenario: A loop that does not reuse slots fails
- **WHEN** the in-memory loop is made to issue a new slot for every link
- **THEN** the dense-slots check fails

#### Scenario: A loop that reuses a slot while Closed is handled fails
- **WHEN** the in-memory loop is made to give a freed slot to a new link before the handlers of its `Closed` have returned
- **THEN** the check that a slot is not reused while `Closed` is handled fails

#### Scenario: A loop that delivers inside dial fails
- **WHEN** the in-memory loop is made to deliver the `Closed` of a failed dial before `dial` returns
- **THEN** the no-event-inside-dial check fails

#### Scenario: A map that ignores generations fails its unit test
- **WHEN** `LinkMap.find` is made to compare slots only
- **THEN** the test of a stale link finding nothing fails

### Requirement: Library scenarios are shown by tests of this repository
The scenarios about what a library does with an event (*A library claims only the events of links it owns*, a dialled link's `Opened`) depend on no event loop and SHALL be shown by tests of the example libraries. `LinkMap` SHALL be tested by unit tests written as one body that runs against any table with the same functions, so that a table written elsewhere can be run against it.

#### Scenario: A table written elsewhere runs the same laws
- **WHEN** the unit test body is run against a table of another layout with `put`, `find` and `drop`
- **THEN** it checks the same scenarios as for `LinkMap`
