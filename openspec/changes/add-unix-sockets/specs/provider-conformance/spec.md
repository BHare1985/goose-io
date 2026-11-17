# Spec Delta

## ADDED Requirements

### Requirement: The unix group has its own suite
The conformance suite SHALL have an entry point for the unix group, run against an event loop that supplies the core and that group. The fixture SHALL supply one absolute path at which the event loop may create a socket, and every other path a check needs SHALL be derived from it. A check of the group SHALL call no operation of another group, `peer_address` included.

#### Scenario: A loop that supplies the group
- **WHEN** a root program passes an event loop that supplies the core and the unix group, and a fixture with a path, to the unix entry point
- **THEN** every check of the group runs against it, and the program's exit status says whether all passed

#### Scenario: A check that reaches into another group
- **WHEN** the operations the unix group's checks call are compared with the groups they belong to
- **THEN** no check calls an operation of a group other than the core

#### Scenario: A loop that does not supply the group
- **WHEN** an event loop that supplies only the core is built
- **THEN** it builds and passes the core suite, and the unix suite is not run against it

### Requirement: The unix suite checks the form's behaviour
The unix suite SHALL check a listener and a dial on a path with data both ways, a path held by a listener, a dial to a path nothing listens on, `listener_port` of a path listener, malformed paths, and the longest path. Each check SHALL name its requirement and have a fault of the in-memory event loop that makes it fail.

#### Scenario: Each check has a fault
- **WHEN** the unix group's checks are compared with the in-memory event loop's faults
- **THEN** every check has at least one fault that makes it fail, recorded in the check table

### Requirement: The in-memory event loop supplies the unix group
The in-memory event loop SHALL supply the unix group, treating a path as the name of an endpoint that a listener holds and a dial reaches. Two paths SHALL conflict only when they are equal, and a path SHALL never conflict with a numeric address. Scripted peers SHALL be able to wait at a path as they wait at an address.

#### Scenario: A scripted peer at a path
- **WHEN** a test scripts a peer to accept a dial at `unix:/run/db.sock` and a library dials that path
- **THEN** the library observes `Opened`, then the peer's scripted `Data`, and the test reads the bytes the library sent

#### Scenario: Paths conflict only when equal
- **WHEN** a library listens on `unix:/run/a.sock`, then on `unix:/run/b.sock` and on `0.0.0.0:8080`
- **THEN** every `listen` succeeds, and a second `listen` on `unix:/run/a.sock` returns `AddressInUse`

### Requirement: The in-memory event loop can refuse the unix form
The in-memory event loop SHALL be configurable to refuse `unix:/path`, reporting `BadAddress` as an event loop that does not supply the group does, so that the refusal can be shown. The core-only event loop of the tests SHALL refuse it.

#### Scenario: A loop configured to refuse the form
- **WHEN** the in-memory event loop is configured to refuse the form and a library dials `unix:/run/a.sock` and listens on it
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`, and `listen` returns an error of kind `BadAddress`

#### Scenario: The core-only loop refuses it
- **WHEN** a library dials `unix:/run/a.sock` on the core-only event loop
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`
