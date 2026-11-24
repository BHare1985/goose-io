## ADDED Requirements

### Requirement: The link handoff capability has its own suite
The conformance suite SHALL have an entry point for the link handoff capability that compiles and runs against a loop supplying the core and link-handoff and nothing else, with at least one check for every scenario of `io-contract` about link-handoff, each naming its requirement. Every check SHALL call only core operations and operations of link-handoff.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and link-handoff to the link-handoff entry point
- **THEN** the program builds and runs every check of link-handoff and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of link-handoff in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies link handoff
The in-memory loop SHALL declare and supply link-handoff,  moving a link's state, its held received bytes and its unsent bytes between in-memory loops of the process. For every check of link-handoff it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: A link moves with its bytes
- **WHEN** a test hands off an in-memory link with 10 unsent bytes and adopts it on a second loop that sends 5 more
- **THEN** the scripted peer receives the 10 bytes then the 5

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of link-handoff names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the link handoff suite
An event loop that supplies link-handoff on real sockets SHALL pass the link-handoff suite on the system it targets in fifty repetitions with no failure before documentation lists it for link-handoff, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the link-handoff suite
- **THEN** `docs/capabilities/link-handoff.md` and the loop's documentation list it as not supplying link-handoff
