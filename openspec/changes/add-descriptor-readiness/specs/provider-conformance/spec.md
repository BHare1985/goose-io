## ADDED Requirements

### Requirement: The descriptor readiness capability has its own suite
The conformance suite SHALL have an entry point for the descriptor readiness capability that compiles and runs against a loop supplying the core and descriptor-readiness and nothing else, with at least one check for every scenario of `io-contract` about descriptor-readiness, each naming its requirement. Every check SHALL call only core operations and operations of descriptor-readiness.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and descriptor-readiness to the descriptor-readiness entry point
- **THEN** the program builds and runs every check of descriptor-readiness and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of descriptor-readiness in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies descriptor readiness
The in-memory loop SHALL declare and supply descriptor-readiness,  over descriptors its fixture creates, which a test marks readable, writable or failed, since it has no real ones. For every check of descriptor-readiness it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: One Ready per arm
- **WHEN** a test marks a watched simulated descriptor readable twice without the library re-arming
- **THEN** the library receives one `Ready`

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of descriptor-readiness names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the descriptor readiness suite
An event loop that supplies descriptor-readiness on real sockets SHALL pass the descriptor-readiness suite on the system it targets in fifty repetitions with no failure before documentation lists it for descriptor-readiness, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the descriptor-readiness suite
- **THEN** `docs/capabilities/descriptor-readiness.md` and the loop's documentation list it as not supplying descriptor-readiness
