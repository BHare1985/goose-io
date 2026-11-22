## ADDED Requirements

### Requirement: The deferred accept capability has its own suite
The conformance suite SHALL have an entry point for the deferred accept capability that compiles and runs against a loop supplying the core and deferred-accept and nothing else, with at least one check for every scenario of `io-contract` about deferred-accept, each naming its requirement. Every check SHALL call only core operations and operations of deferred-accept.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and deferred-accept to the deferred-accept entry point
- **THEN** the program builds and runs every check of deferred-accept and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of deferred-accept in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies deferred accept
The in-memory loop SHALL declare and supply deferred-accept,  holding an accepted link until its first bytes arrive or the time passes on the virtual clock. For every check of deferred-accept it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: A silent connection is not opened
- **WHEN** a test connects to a deferring in-memory listener and sends nothing for less than `ms`
- **THEN** the server library sees no `Opened`

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of deferred-accept names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the deferred accept suite
An event loop that supplies deferred-accept on real sockets SHALL pass the deferred-accept suite on the system it targets in fifty repetitions with no failure before documentation lists it for deferred-accept, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the deferred-accept suite
- **THEN** `docs/capabilities/deferred-accept.md` and the loop's documentation list it as not supplying deferred-accept
