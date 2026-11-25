## ADDED Requirements

### Requirement: The shared listen capability has its own suite
The conformance suite SHALL have an entry point for the shared listen capability that compiles and runs against a loop supplying the core and shared-listen and nothing else, with at least one check for every scenario of `io-contract` about shared-listen, each naming its requirement. Every check SHALL call only core operations and operations of shared-listen.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and shared-listen to the shared-listen entry point
- **THEN** the program builds and runs every check of shared-listen and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of shared-listen in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies shared listen
The in-memory loop SHALL declare and supply shared-listen,  so several shared listeners of one in-memory loop can hold one address (an in-memory address belongs to one loop; the suite gets one loop and checks with two listeners in it), spreading connections round-robin in a fixed order so tests repeat. For every check of shared-listen it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Connections are spread
- **WHEN** two shared listeners of an in-memory loop hold one address and ten clients connect
- **THEN** each connection is accepted by exactly one listener, five each

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of shared-listen names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the shared listen suite
An event loop that supplies shared-listen on real sockets SHALL pass the shared-listen suite on the system it targets in fifty repetitions with no failure before documentation lists it for shared-listen, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the shared-listen suite
- **THEN** `docs/capabilities/shared-listen.md` and the loop's documentation list it as not supplying shared-listen
