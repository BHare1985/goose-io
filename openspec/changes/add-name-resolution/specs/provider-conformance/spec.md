## ADDED Requirements

### Requirement: The name resolution capability has its own suite
The conformance suite SHALL have an entry point for the name resolution capability that compiles and runs against a loop supplying the core and name-resolution and nothing else, with at least one check for every scenario of `io-contract` about name-resolution, each naming its requirement. Every check SHALL call only core operations and operations of name-resolution.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and name-resolution to the name-resolution entry point
- **THEN** the program builds and runs every check of name-resolution and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of name-resolution in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies name resolution
The in-memory loop SHALL declare and supply name-resolution,  answering from a table of names the test scripts, with a scripted delay on the virtual clock. For every check of name-resolution it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: A scripted name
- **WHEN** a test scripts `db.test` as two addresses and resolves it
- **THEN** `Resolved` arrives with status `Found`, count 2, and both addresses in the scripted order

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of name-resolution names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the name resolution suite
An event loop that supplies name-resolution on real sockets SHALL pass the name-resolution suite on the system it targets in fifty repetitions with no failure before documentation lists it for name-resolution, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the name-resolution suite
- **THEN** `docs/capabilities/name-resolution.md` and the loop's documentation list it as not supplying name-resolution
