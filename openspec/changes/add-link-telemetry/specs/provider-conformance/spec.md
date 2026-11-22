## ADDED Requirements

### Requirement: The link telemetry capability has its own suite
The conformance suite SHALL have an entry point for the link telemetry capability that compiles and runs against a loop supplying the core and link-telemetry and nothing else, with at least one check for every scenario of `io-contract` about link-telemetry, each naming its requirement. Every check SHALL call only core operations and operations of link-telemetry.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and link-telemetry to the link-telemetry entry point
- **THEN** the program builds and runs every check of link-telemetry and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of link-telemetry in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies link telemetry
The in-memory loop SHALL declare and supply link-telemetry,  counting bytes exactly and reporting a round-trip time from the latency the test scripts for each peer, with -1 for fields it does not model. For every check of link-telemetry it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Counters match the bytes
- **WHEN** a test sends 300 bytes on an in-memory link and the peer reads them
- **THEN** `link_stats` reports 300 accepted and 300 handed to the transport

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of link-telemetry names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the link telemetry suite
An event loop that supplies link-telemetry on real sockets SHALL pass the link-telemetry suite on the system it targets in fifty repetitions with no failure before documentation lists it for link-telemetry, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the link-telemetry suite
- **THEN** `docs/capabilities/link-telemetry.md` and the loop's documentation list it as not supplying link-telemetry
