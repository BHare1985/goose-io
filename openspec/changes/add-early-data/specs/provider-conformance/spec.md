## ADDED Requirements

### Requirement: The early data capability has its own suite
The conformance suite SHALL have an entry point for the early data capability that compiles and runs against a loop supplying the core and early-data and nothing else, with at least one check for every scenario of `io-contract` about early-data, each naming its requirement. Every check SHALL call only core operations and operations of early-data.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and early-data to the early-data entry point
- **THEN** the program builds and runs every check of early-data and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of early-data in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies early data
The in-memory loop SHALL declare and supply early-data,  sending the early bytes with the opening of its in-memory connection and delivering them on an accepting listener as the first `Data`, with a fault fixture that delivers them twice to show the replay rule. For every check of early-data it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Early bytes arrive first
- **WHEN** a test dials an in-memory listener that accepts early data with 50 bytes
- **THEN** the server library sees `Opened` then a `Data` of those 50 bytes before any other

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of early-data names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the early data suite
An event loop that supplies early-data on real sockets SHALL pass the early-data suite on the system it targets in fifty repetitions with no failure before documentation lists it for early-data, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the early-data suite
- **THEN** `docs/capabilities/early-data.md` and the loop's documentation list it as not supplying early-data
