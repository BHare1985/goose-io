# Spec Delta

## ADDED Requirements

### Requirement: The suite is run one group at a time
The conformance suite SHALL have one entry point for the core and one for each group of extras, and each SHALL compile and run against an event loop that supplies the core and that group, and nothing else. Every check SHALL belong to exactly one of them: a check of the core SHALL call no operation of a group, and a check of a group SHALL call no operation of another group.

#### Scenario: The core suite on a loop with only the core
- **WHEN** a root program passes an event loop that supplies only the core to the core entry point
- **THEN** the program builds and runs every check of the core, and none of a group

#### Scenario: A group suite
- **WHEN** a root program passes an event loop that supplies the core and the sizing group to the sizing entry point
- **THEN** every check of the sizing group runs against it

#### Scenario: A check that reaches into another group
- **WHEN** the operations a check calls are compared with the group it belongs to
- **THEN** the check calls no operation outside the core and its own group

### Requirement: The conformance suite is event-loop-neutral
The project SHALL ship a conformance suite written only against the I/O contract and generic over the event loop. The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of an event loop, and each check SHALL name the requirement it proves and the group it belongs to.

#### Scenario: Every contract scenario is covered
- **WHEN** the list of `io-contract` scenarios is compared with the suite's checks
- **THEN** each scenario about the behaviour of an event loop has at least one check that names it, and each remaining scenario names the build or inspection step that proves it

#### Scenario: The suite names no event loop
- **WHEN** the suite's sources are inspected
- **THEN** they import the contract and nothing that names a specific event loop

### Requirement: An event loop says which groups it passes
An event loop SHALL be described as conforming to the core only after the core suite passes against it on the operating system it targets, and as supplying a group only after that group's suite passes. Documentation SHALL state, for each event loop, the contract version, the commit at which each of its groups last passed, and the groups it does not supply.

#### Scenario: An event loop that fails a check
- **WHEN** an event loop fails any conformance check of a group
- **THEN** the suite exits with a failure status naming the check, the requirement and the group, and the documentation does not list that group for that loop

#### Scenario: A loop that passes only the core
- **WHEN** an event loop passes the core suite and supplies no group
- **THEN** the documentation lists it as conforming to the core, with no group

### Requirement: The suite is a tool and not a gate
Nothing in the conformance suite SHALL prevent the use of an event loop that passes less than all of it, and a library SHALL need to be tested only on the groups it uses. The suite SHALL report what failed and where, and leave the decision to the person who chooses the loop.

#### Scenario: A library on a loop that passes only some groups
- **WHEN** a library uses only the core and the sizing group, and the loop passes those two
- **THEN** the library is supported on that loop whatever the loop does for the other groups

## MODIFIED Requirements

### Requirement: An event loop in any repository can run the suite
An event loop's author SHALL be able to run the suite for the core, and for each group the loop supplies, from the loop's own repository by importing it and supplying the loop and a small fixture. The fixture SHALL supply only what contract calls cannot produce: an address that never answers, an address that is already held, and an address that nothing listens on.

#### Scenario: Running the suite from outside
- **WHEN** a root program outside the contract package imports the suite, constructs an event loop and passes it with a fixture to the entry point of one group
- **THEN** every check of that group runs against that loop and the program's exit status reports whether all passed

### Requirement: Every check is shown to fail on a broken event loop
For every conformance check there SHALL be a recorded fault that the in-memory event loop can be switched to exhibit, and the check SHALL fail when that fault is on. A check that passes against its fault SHALL be treated as a defect in the suite.

#### Scenario: A fault is detected
- **WHEN** the in-memory event loop is switched to deliver `Data` after `Closed` and the suite is run
- **THEN** the check for link event order fails and names that requirement

#### Scenario: No check is untested
- **WHEN** the list of checks is compared with the list of faults
- **THEN** every check has at least one fault that makes it fail

### Requirement: An in-memory event loop for deterministic tests
The project SHALL ship an event loop that implements the whole contract, the core and every group, in memory, with no sockets and a clock that moves only when the test or the loop advances it. A test SHALL be able to script a peer: connect, accept or refuse a dial, send bytes, stop and resume reading, half-close, close and abort. A test SHALL be able to read what a library sent on each link.

#### Scenario: A library test without a network
- **WHEN** a test scripts a peer that accepts a dial and sends a reply in two parts, and the clock is advanced past a deadline
- **THEN** the library under test observes `Opened`, two `Data` events and the `Tick` in that order, and the test completes without opening a socket or sleeping

#### Scenario: Two links on one loop are joined
- **WHEN** a library listens on an address and another library on the same loop dials it
- **THEN** both links open, and bytes sent on one arrive as `Data` on the other, subject to the same backpressure rules as any link

#### Scenario: The same run twice
- **WHEN** the same test is run twice against the in-memory event loop
- **THEN** both runs deliver the same events in the same order at the same clock times

### Requirement: Example libraries prove composition
The project SHALL ship a small server library and a small client library written only against the contract, and each SHALL say which parts of the contract it needs. The client SHALL need only the core; it SHALL keep a pool of outbound links, pipeline requests, apply a per-request deadline, reconnect with backoff after a lost link, and respect send backpressure. Both SHALL be exercised by tests on the in-memory event loop.

#### Scenario: The client survives a lost link
- **WHEN** a scripted peer aborts a pooled link with requests outstanding
- **THEN** each outstanding request is reported as failed exactly once, and a later request is sent on a new link dialled after the backoff period

#### Scenario: The client shares a loop with a server library
- **WHEN** a program runs the server library and the client library on one loop, and a request to the server is answered using a reply fetched through the client
- **THEN** the request is answered correctly and neither library's source names the other

#### Scenario: A deadline expires
- **WHEN** a scripted peer accepts a request and never replies, and the clock passes the request's deadline
- **THEN** the request is reported as timed out once, and a reply arriving later is discarded without being matched to another request

#### Scenario: A library states what it needs
- **WHEN** the example libraries' sources are inspected
- **THEN** each names the groups of the contract it uses, and a program that builds the client against an event loop that supplies only the core succeeds

### Requirement: Candidate event loops have a recorded mapping
For each planned example event loop and each event-loop library the contract claims to fit, the project SHALL record how every contract operation and event maps onto that loop's own interface at a named revision of its source, with the core and each group in their own part of the record. Each row SHALL be marked as checked against the source or as unverified, and an operation with no workable mapping SHALL be resolved in the contract or recorded as a known gap before the contract version is published.

#### Scenario: Every operation has a row
- **WHEN** a mapping document is compared with the operations and events of the contract
- **THEN** each has a row, marked as part of the core or of one group

#### Scenario: Unverified points are visible
- **WHEN** a row rests on a claim that was not checked against the event loop's source
- **THEN** the row says so, and the list of unverified rows appears at the top of the mapping

#### Scenario: What a core-only loop costs
- **WHEN** a mapping document is read
- **THEN** it lists the adapter work for the core separately from that for each group, so that the cost of a loop that supplies only the core can be read from it

## REMOVED Requirements

### Requirement: The conformance suite is provider-neutral
**Reason**: one of its scenarios names a "provider", and a modified requirement may not rename a scenario; replaced by *The conformance suite is event-loop-neutral*.
**Migration**: use *The conformance suite is event-loop-neutral*.

### Requirement: A provider is admitted only by passing the suite
**Reason**: conformance is now by group and the suite is a tool and not a gate, and its scenario names a "provider"; replaced by *An event loop says which groups it passes*.
**Migration**: use *An event loop says which groups it passes*.

## RENAMED Requirements

- FROM: `### Requirement: A provider in any repository can run the suite`
- TO: `### Requirement: An event loop in any repository can run the suite`
- FROM: `### Requirement: Every check is shown to fail on a broken provider`
- TO: `### Requirement: Every check is shown to fail on a broken event loop`
- FROM: `### Requirement: An in-memory provider for deterministic tests`
- TO: `### Requirement: An in-memory event loop for deterministic tests`
- FROM: `### Requirement: Candidate providers have a recorded mapping`
- TO: `### Requirement: Candidate event loops have a recorded mapping`
