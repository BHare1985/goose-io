## ADDED Requirements

### Requirement: Each new group has its own suite
The conformance suite SHALL have an entry point for each of the relay, peek, revoke, wake, files, loans, parts and addresses groups, each compiling and running against a loop that supplies the core and that group and nothing else. Every check of a group SHALL call no operation of another group.

#### Scenario: A group suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and the peek group to the peek entry point
- **THEN** the program builds and runs every check of the peek group and none of another group

#### Scenario: A check that reaches into another group
- **WHEN** the operations a check of the relay group calls are compared with the groups of the contract
- **THEN** it calls only core operations and operations of the relay group

### Requirement: Every scenario of a new group has a check
The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of one of the new groups, each naming the requirement it proves. A scenario that needs two groups together (a write deadline on a relayed link) SHALL be checked by a test of this repository that supplies both, and not by a group's entry point.

#### Scenario: Every new scenario is covered
- **WHEN** the scenarios of the new groups in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

#### Scenario: Two groups together
- **WHEN** a scenario needs the revoke and relay groups at once
- **THEN** a test of this repository that supplies both checks it

### Requirement: The in-memory loop supplies every new group
The in-memory loop SHALL supply the relay, peek, revoke, wake, files, loans, parts and addresses groups, with scripted peers able to send, end, reset and not read, so that each group's suite runs against it with a virtual clock and no network. It SHALL be able to bound each group's buffers by configuration, as it bounds links and buffers now. A file of the in-memory loop SHALL be an in-memory byte range registered by the test.

#### Scenario: The suite of a new group runs in memory
- **WHEN** the relay suite is run against the in-memory loop
- **THEN** every check passes, and a repetition produces the same output as the first

#### Scenario: A thread wakes the in-memory loop
- **WHEN** a test thread calls `wake` on the in-memory loop's waker during `serve`
- **THEN** `Woken` is delivered on the loop's thread

### Requirement: Every check of a new group is shown to fail
For every check of the new groups the in-memory loop SHALL have a named fault that makes the check fail, and the fault script SHALL show it, so that a check that passes against its own fault is reported as a defect in the suite.

#### Scenario: A relay that drops a byte
- **WHEN** the in-memory loop is switched to the fault in which `relay` drops the last byte of a message
- **THEN** the relay check of intact bytes fails and names the requirement

#### Scenario: A write deadline that is read at the start of the pass
- **WHEN** the loop is switched to the fault in which a write deadline is compared with the clock at the start of the pass and not at the write
- **THEN** the check that no byte is written after the deadline fails

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of a new group names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the new groups
An event loop that supplies a new group on real sockets SHALL pass that group's suite on the system it targets, in fifty repetitions with no failure, before documentation lists it for that group, and SHALL hold the system-call, throughput and memory numbers of its own gates with the group present and unused.

#### Scenario: The epoll ext loop passes the relay suite
- **WHEN** the relay suite is run fifty times against `goose-io-epoll-ext`
- **THEN** every repetition passes, and the loop is listed for relay with the commit at which it passed

#### Scenario: A group that is not supplied is not listed
- **WHEN** a loop has not passed a group's suite
- **THEN** the documentation lists the group under the groups it does not supply
