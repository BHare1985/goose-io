## ADDED Requirements

### Requirement: The mutable data capability has its own suite
The conformance suite SHALL have an entry point for the mutable data capability that compiles and runs against a loop supplying the core and mutable-data and nothing else, with at least one check for every scenario of `io-contract` about mutable-data, each naming its requirement. Every check SHALL call only core operations and operations of mutable-data.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and mutable-data to the mutable-data entry point
- **THEN** the program builds and runs every check of mutable-data and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of mutable-data in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies mutable data
The in-memory loop SHALL declare and supply mutable-data,  lending its own delivery buffer writable and refreshing it for every event, so a write never shows in a later event. For every check of mutable-data it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Writes stay in the handler
- **WHEN** a test library changes every byte through `data_mut` and the peer sends again
- **THEN** the next `Data` carries the peer's bytes, not the changed ones

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of mutable-data names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the mutable data suite
An event loop that supplies mutable-data on real sockets SHALL pass the mutable-data suite on the system it targets in fifty repetitions with no failure before documentation lists it for mutable-data, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the mutable-data suite
- **THEN** `docs/capabilities/mutable-data.md` and the loop's documentation list it as not supplying mutable-data
