## ADDED Requirements

### Requirement: Each new group has its own suite
The conformance suite SHALL have an entry point for each of the files, loans, parts and addresses groups, each compiling and running against a loop that supplies the core and that group and nothing else. Every check of a group SHALL call no operation of another group.

#### Scenario: A group suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and the parts group to the parts entry point
- **THEN** the program builds and runs every check of the parts group and none of another group

#### Scenario: A check that reaches into another group
- **WHEN** the operations a check of the files group calls are compared with the groups of the contract
- **THEN** it calls only core operations and operations of the files group

### Requirement: Every scenario of a new group has a check
The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of one of the new groups, each naming the requirement it proves.

#### Scenario: Every new scenario is covered
- **WHEN** the scenarios of the new groups in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies every new group
The in-memory loop SHALL supply the files, loans, parts and addresses groups, so that each group's suite runs against it with a virtual clock and no network. It SHALL be able to bound each group's buffers by configuration, as it bounds links and buffers now. A file of the in-memory loop SHALL be an in-memory byte range registered by the test.

#### Scenario: The suite of a new group runs in memory
- **WHEN** the parts suite is run against the in-memory loop
- **THEN** every check passes, and a repetition produces the same output as the first

#### Scenario: A file is read from memory
- **WHEN** the test registers a byte range as a file and a library sends it with `send_file`
- **THEN** the scripted peer receives exactly those bytes

### Requirement: Every check of a new group is shown to fail
For every check of the new groups the in-memory loop SHALL have a named fault that makes the check fail, and the fault script SHALL show it, so that a check that passes against its own fault is reported as a defect in the suite.

#### Scenario: A parts send that drops a part
- **WHEN** the in-memory loop is switched to the fault in which `send_parts` drops its last part
- **THEN** the check of joined bytes fails and names the requirement

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of a new group names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the new groups
An event loop that supplies a new group on real sockets SHALL pass that group's suite on the system it targets, in fifty repetitions with no failure, before documentation lists it for that group, and SHALL hold the system-call, throughput and memory numbers of its own gates with the group present and unused.

#### Scenario: The epoll ext loop passes the files suite
- **WHEN** the files suite is run fifty times against `goose-io-epoll-ext`
- **THEN** every repetition passes, and the loop is listed for files with the commit at which it passed

#### Scenario: A group that is not supplied is not listed
- **WHEN** a loop has not passed a group's suite
- **THEN** the documentation lists the group under the groups it does not supply
