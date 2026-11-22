## ADDED Requirements

### Requirement: Each stream capability has its own suite
The conformance suite SHALL have an entry point for each of the files, loans, parts and addresses capabilities, each compiling and running against a loop that supplies the core and that capability and nothing else. Every check of a capability SHALL call no operation of another capability.

#### Scenario: A capability suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and the parts capability to the parts entry point
- **THEN** the program builds and runs every check of the parts capability and none of another capability

#### Scenario: A check that reaches into another capability
- **WHEN** the operations a check of the files capability calls are compared with the capabilities of the contract
- **THEN** it calls only core operations and operations of the files capability

### Requirement: Every scenario of a stream capability has a check
The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of one of the stream capabilities, each naming the requirement it proves.

#### Scenario: Every new scenario is covered
- **WHEN** the scenarios of the stream capabilities in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies every stream capability
The in-memory loop SHALL supply the files, loans, parts and addresses capabilities, so that each capability's suite runs against it with a virtual clock and no network. It SHALL be able to bound each capability's buffers by configuration, as it bounds links and buffers now. A file of the in-memory loop SHALL be an in-memory byte range registered by the test.

#### Scenario: The suite of a stream capability runs in memory
- **WHEN** the parts suite is run against the in-memory loop
- **THEN** every check passes, and a repetition produces the same output as the first

#### Scenario: A file is read from memory
- **WHEN** the test registers a byte range as a file and a library sends it with `send_file`
- **THEN** the scripted peer receives exactly those bytes

### Requirement: Every check of a stream capability is shown to fail
For every check of the stream capabilities the in-memory loop SHALL have a named fault that makes the check fail, and the fault script SHALL show it, so that a check that passes against its own fault is reported as a defect in the suite.

#### Scenario: A parts send that drops a part
- **WHEN** the in-memory loop is switched to the fault in which `send_parts` drops its last part
- **THEN** the check of joined bytes fails and names the requirement

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of a stream capability names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the stream capabilities
An event loop that supplies a stream capability on real sockets SHALL pass that capability's suite on the system it targets, in fifty repetitions with no failure, before documentation lists it for that capability, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability present and unused.

#### Scenario: The epoll ext loop passes the files suite
- **WHEN** the files suite is run fifty times against `goose-io-epoll-ext`
- **THEN** every repetition passes, and the loop is listed for files with the commit at which it passed

#### Scenario: A capability that is not supplied is not listed
- **WHEN** a loop has not passed a capability's suite
- **THEN** the documentation lists the capability under the capabilities it does not supply
