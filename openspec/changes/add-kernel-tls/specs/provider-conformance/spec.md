## ADDED Requirements

### Requirement: The kernel TLS capability has its own suite
The conformance suite SHALL have an entry point for the kernel TLS capability that compiles and runs against a loop supplying the core and kernel-tls and nothing else, with at least one check for every scenario of `io-contract` about kernel-tls, each naming its requirement. Every check SHALL call only core operations and operations of kernel-tls.

#### Scenario: The suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and kernel-tls to the kernel-tls entry point
- **THEN** the program builds and runs every check of kernel-tls and none of another capability

#### Scenario: Every scenario is covered
- **WHEN** the scenarios of kernel-tls in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

### Requirement: The in-memory loop supplies kernel TLS
The in-memory loop SHALL declare and supply kernel-tls,  with the `TestOnly` cipher only: a record layer that frames, numbers and transforms records so the scripted peer sees ciphertext, and refusing every real cipher with `Unsupported`. For every check of kernel-tls it SHALL have a named fault that makes the check fail, shown by the fault script.

#### Scenario: Plaintext in, records out
- **WHEN** a test installs `TestOnly` send keys on an in-memory link and sends 100 bytes
- **THEN** the scripted peer receives one record whose decryption with the same keys is the 100 bytes

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of kernel-tls names a fault, and the table check fails when one does not

### Requirement: A loop on a real system passes the kernel TLS suite
An event loop that supplies kernel-tls on real sockets SHALL pass the kernel-tls suite on the system it targets in fifty repetitions with no failure before documentation lists it for kernel-tls, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability declared and unused.

#### Scenario: A loop that has not passed
- **WHEN** a loop has not passed the kernel-tls suite
- **THEN** `docs/capabilities/kernel-tls.md` and the loop's documentation list it as not supplying kernel-tls
