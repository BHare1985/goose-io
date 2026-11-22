## ADDED Requirements

### Requirement: The transport hints capability has its own suite
The conformance suite SHALL have an entry point for the transport hints capability that compiles and runs against a loop supplying the core and transport-hints and nothing else, with at least one check for every scenario of `io-contract` about transport-hints, each naming its requirement. Every check SHALL call only core operations and operations of transport-hints.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and transport-hints to the transport-hints entry point
- **THEN** the program builds and runs every check of transport-hints and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of transport-hints in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies transport hints
The in-memory loop SHALL declare and supply transport-hints,  recording each hint for the fixture, holding a `Coalesce` link's bytes until the end of the pass, delivering `Writable` against `SendLowWater`, and spreading a paced link's bytes over the virtual clock. For every check of transport-hints it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Coalesced bytes are handed over at the end of the pass
- **WHEN** a test sends three small parts on a coalescing in-memory link in one pass
- **THEN** the scripted peer receives them in one transport write after the pass

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of transport-hints names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the transport hints suite
An event loop that supplies transport-hints on real sockets SHALL pass the transport-hints suite on the system it targets in fifty repetitions with no failure before documentation lists it for transport-hints, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the transport-hints suite
- **THEN** `docs/capabilities/transport-hints.md` and the loop's documentation list it as not supplying transport-hints
