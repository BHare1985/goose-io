# Spec Delta

## Purpose

Defines how a provider is shown to satisfy the I/O contract: one conformance suite written only against the contract, a fake provider for tests without sockets, and an example client library that proves a library runs unchanged across providers.

## ADDED Requirements

### Requirement: The conformance suite is provider-neutral
The project SHALL ship a conformance suite whose test programs are written only against the I/O contract and take the provider as a build-time choice. The suite SHALL contain at least one check for every scenario of the `io-contract` capability, and each check SHALL name the requirement it proves.

#### Scenario: The same suite, a different provider
- **WHEN** the suite is built for the reference epoll provider and again for the fake provider
- **THEN** the test programs' sources are identical in both builds and only the provider selection differs

#### Scenario: Every contract scenario is covered
- **WHEN** the list of `io-contract` scenarios is compared with the suite's checks
- **THEN** each scenario has at least one check that names it

### Requirement: A provider is admitted only by passing the suite
A provider SHALL be described as conforming only after the whole suite passes against it on the operating system it targets. Documentation SHALL state, for each provider, the commit at which it last passed.

#### Scenario: A provider that fails a check
- **WHEN** a provider fails any conformance check
- **THEN** the suite exits with a failure status naming the check and the requirement, and the documentation does not list that provider as conforming

### Requirement: Failures are never hidden by repetition
The suite SHALL be repeatable on demand, and a check that fails in any repetition SHALL be reported as failed. A check that fails intermittently SHALL be treated as failing until its cause is explained.

#### Scenario: An intermittent failure
- **WHEN** the suite is run fifty times and one check fails once
- **THEN** the run reports that check as failed and keeps the failing output

### Requirement: A fake provider for deterministic tests
The project SHALL ship a provider that implements the contract entirely in memory, with no sockets and no real clock. A test SHALL be able to script it: complete or fail a dial, deliver bytes to a link, close a link with a chosen reason, refuse sends as `Full` and later reopen them, advance time, and end a pass. A test SHALL be able to read what a library sent on each link.

#### Scenario: A library test without a network
- **WHEN** a test scripts the fake provider to open a dialled link, deliver a reply split across two `Data` events, and advance the clock past a deadline
- **THEN** the library under test observes exactly those events in that order, and the test completes without opening a socket or sleeping

#### Scenario: The fake provider obeys the contract's ordering
- **WHEN** a test scripts an event that the contract forbids, such as `Data` after `Closed` or a second `Opened`
- **THEN** the fake provider rejects the script with a failure naming the violated rule

### Requirement: An example client library proves portability
The project SHALL ship a small client library, written only against the contract, that keeps a pool of outbound links, pipelines requests, applies a per-request deadline, reconnects with backoff after a lost link, and respects send backpressure. It SHALL be exercised by tests on both the reference epoll provider and the fake provider.

#### Scenario: The same client on two providers
- **WHEN** the example client's tests are run on the epoll provider against a real echo service and on the fake provider with scripted events
- **THEN** both runs pass with no change to the client's source

#### Scenario: The client shares a worker with a server library
- **WHEN** a program runs a small server library and the example client on one worker, and a request to the server is answered using a reply fetched through the client
- **THEN** the request is answered correctly and neither library's source names the other
