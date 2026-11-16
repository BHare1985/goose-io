# Spec Delta

## Purpose

Defines how a provider is shown to satisfy the I/O contract and how a library is tested against it: one conformance suite written only against the contract, an in-memory provider for tests without sockets, example libraries that prove composition, and a recorded mapping for each candidate provider.

## ADDED Requirements

### Requirement: The conformance suite is provider-neutral
The project SHALL ship a conformance suite written only against the I/O contract and generic over the provider. The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes provider behaviour, and each check SHALL name the requirement it proves.

#### Scenario: Every contract scenario is covered
- **WHEN** the list of `io-contract` scenarios is compared with the suite's checks
- **THEN** each scenario about provider behaviour has at least one check that names it, and each remaining scenario names the build or inspection step that proves it

#### Scenario: The suite names no provider
- **WHEN** the suite's sources are inspected
- **THEN** they import the contract and nothing that names a specific provider

### Requirement: A provider in any repository can run the suite
A provider's author SHALL be able to run the whole suite from the provider's own repository by importing it and supplying the provider's loop and a small fixture. The fixture SHALL supply only what contract calls cannot produce: an address that never answers and an address that is already held.

#### Scenario: Running the suite from outside
- **WHEN** a root program outside the contract package imports the suite, constructs a provider and passes it with a fixture to the suite's entry point
- **THEN** every check runs against that provider and the program's exit status reports whether all passed

### Requirement: A provider is admitted only by passing the suite
A provider SHALL be described as conforming only after the whole suite passes against it on the operating system it targets. Documentation SHALL state, for each provider, the contract version and the commit at which it last passed.

#### Scenario: A provider that fails a check
- **WHEN** a provider fails any conformance check
- **THEN** the suite exits with a failure status naming the check and the requirement, and the documentation does not list that provider as conforming

### Requirement: Every check is shown to fail on a broken provider
For every conformance check there SHALL be a recorded fault that the in-memory provider can be switched to exhibit, and the check SHALL fail when that fault is on. A check that passes against its fault SHALL be treated as a defect in the suite.

#### Scenario: A fault is detected
- **WHEN** the in-memory provider is switched to deliver `Data` after `Closed` and the suite is run
- **THEN** the check for link event order fails and names that requirement

#### Scenario: No check is untested
- **WHEN** the list of checks is compared with the list of faults
- **THEN** every check has at least one fault that makes it fail

### Requirement: Failures are never hidden by repetition
The suite SHALL be repeatable on demand, and a check that fails in any repetition SHALL be reported as failed. A check that fails intermittently SHALL be treated as failing until its cause is explained.

#### Scenario: An intermittent failure
- **WHEN** the suite is run fifty times and one check fails once
- **THEN** the run reports that check as failed and keeps the failing output

### Requirement: An in-memory provider for deterministic tests
The project SHALL ship a provider that implements the whole contract in memory, with no sockets and a clock that moves only when the test or the loop advances it. A test SHALL be able to script a peer: connect, accept or refuse a dial, send bytes, stop and resume reading, half-close, close and abort. A test SHALL be able to read what a library sent on each link.

#### Scenario: A library test without a network
- **WHEN** a test scripts a peer that accepts a dial and sends a reply in two parts, and the clock is advanced past a deadline
- **THEN** the library under test observes `Opened`, two `Data` events and the `Tick` in that order, and the test completes without opening a socket or sleeping

#### Scenario: Two links on one loop are joined
- **WHEN** a library listens on an address and another library on the same loop dials it
- **THEN** both links open, and bytes sent on one arrive as `Data` on the other, subject to the same backpressure rules as any link

#### Scenario: The same run twice
- **WHEN** the same test is run twice against the in-memory provider
- **THEN** both runs deliver the same events in the same order at the same clock times

### Requirement: Example libraries prove composition
The project SHALL ship a small server library and a small client library written only against the contract. The client SHALL keep a pool of outbound links, pipeline requests, apply a per-request deadline, reconnect with backoff after a lost link, and respect send backpressure. Both SHALL be exercised by tests on the in-memory provider.

#### Scenario: The client survives a lost link
- **WHEN** a scripted peer aborts a pooled link with requests outstanding
- **THEN** each outstanding request is reported as failed exactly once, and a later request is sent on a new link dialled after the backoff period

#### Scenario: The client shares a loop with a server library
- **WHEN** a program runs the server library and the client library on one loop, and a request to the server is answered using a reply fetched through the client
- **THEN** the request is answered correctly and neither library's source names the other

#### Scenario: A deadline expires
- **WHEN** a scripted peer accepts a request and never replies, and the clock passes the request's deadline
- **THEN** the request is reported as timed out once, and a reply arriving later is discarded without being matched to another request

### Requirement: Candidate providers have a recorded mapping
For each planned example provider and each event-loop library the contract claims to fit, the project SHALL record how every contract operation and event maps onto that provider's own interface at a named revision of its source. Each row SHALL be marked as checked against the source or as unverified, and an operation with no workable mapping SHALL be resolved in the contract or recorded as a known gap before the contract version is published.

#### Scenario: Every operation has a row
- **WHEN** the mapping for a candidate provider is compared with the contract's operations and events
- **THEN** each has a row naming the provider's corresponding call or callback, or stating that the adapter must supply it and how

#### Scenario: Unverified points are visible
- **WHEN** a row rests on a claim that was not checked against the provider's source
- **THEN** the row says so, and the list of unverified rows appears at the top of the mapping
