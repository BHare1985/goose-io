## ADDED Requirements

### Requirement: The retained data capability has its own suite
The conformance suite SHALL have an entry point for the retained data capability that compiles and runs against a loop supplying the core and retained-data and nothing else, with at least one check for every scenario of `io-contract` about retained-data, each naming its requirement. Every check SHALL call only core operations and operations of retained-data.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and retained-data to the retained-data entry point
- **THEN** the program builds and runs every check of retained-data and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of retained-data in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies retained data
The in-memory loop SHALL declare and supply retained-data,  keeping retained bytes in a bounded store of its own (a copy, which conforms) and reporting the store's bound. For every check of retained-data it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Retained bytes outlive the handler
- **WHEN** a test library retains a `Data` and reads `retained_bytes` in a later pass
- **THEN** the bytes are those of the event, unchanged

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of retained-data names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the retained data suite
An event loop that supplies retained-data on real sockets SHALL pass the retained-data suite on the system it targets in fifty repetitions with no failure before documentation lists it for retained-data, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the retained-data suite
- **THEN** `docs/capabilities/retained-data.md` and the loop's documentation list it as not supplying retained-data
