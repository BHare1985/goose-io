## ADDED Requirements

### Requirement: The listener inheritance capability has its own suite
The conformance suite SHALL have an entry point for the listener inheritance capability that compiles and runs against a loop supplying the core and listener-inheritance and nothing else, with at least one check for every scenario of `io-contract` about listener-inheritance, each naming its requirement. Every check SHALL call only core operations and operations of listener-inheritance.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and listener-inheritance to the listener-inheritance entry point
- **THEN** the program builds and runs every check of listener-inheritance and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of listener-inheritance in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies listener inheritance
The in-memory loop SHALL declare and supply listener-inheritance,  with a process-wide table standing for the unix path, so one in-memory loop exports and another adopts, queued connections included. For every check of listener-inheritance it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: No connection is refused
- **WHEN** a test exports a listener while clients connect and a second loop adopts it
- **THEN** every client connection is accepted by one of the two loops

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of listener-inheritance names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the listener inheritance suite
An event loop that supplies listener-inheritance on real sockets SHALL pass the listener-inheritance suite on the system it targets in fifty repetitions with no failure before documentation lists it for listener-inheritance, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the listener-inheritance suite
- **THEN** `docs/capabilities/listener-inheritance.md` and the loop's documentation list it as not supplying listener-inheritance
