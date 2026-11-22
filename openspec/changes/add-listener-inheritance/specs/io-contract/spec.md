## ADDED Requirements

### Requirement: The listener inheritance capability is named by its parts
The contract SHALL have an optional capability named listener-inheritance, made of the operations `adopt_listener(address) -> Listener, ListenError` and `export_listeners(to) -> i64`, and the listen error kind `NotInherited`. It SHALL have the declaration `supplies_listener_inheritance`, the query `has_listener_inheritance` and the compile-time check `require_listener_inheritance`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `adopt_listener` without a compile-time branch is built against an event loop that does not declare listener-inheritance
- **THEN** the build fails and the error names `supplies_listener_inheritance` or `adopt_listener`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `adopt_listener` only in the branch taken when `goose_io::has_listener_inheritance` is `Supplied` is built against the core-only loop
- **THEN** it builds, and the application listens with `listen` and accepts a short refusal during a restart

### Requirement: Adopt listener takes an inherited socket
`adopt_listener(address)` SHALL return a listener for a socket the loop holds by inheritance that is already listening on `address`, without binding, and SHALL deliver connections queued on it before the adoption. The listener SHALL then behave as one from `listen`. Each inherited socket SHALL be adopted at most once.

#### Scenario: A socket from systemd
- **WHEN** a loop started with an inherited socket listening on port 8080 is asked to adopt that address
- **THEN** it returns a listener and the first `Opened` may be a connection made before the process started

### Requirement: Nothing inherited is an error of its own
`adopt_listener` SHALL fail with `NotInherited` when the loop holds no inherited socket for `address`, or that socket was already adopted, so the application can fall back to `listen`. It SHALL fail with `BadAddress` for an address `listen` would refuse.

#### Scenario: A first start
- **WHEN** a server started with no inherited sockets calls `adopt_listener`
- **THEN** it fails with `NotInherited` and the server calls `listen`

### Requirement: Export listeners hands every listener to another process
`export_listeners(to)` SHALL send every active listener of the loop, with the connections queued on it, to the process receiving on the unix path `to`, and SHALL then stop them as `stop_listening` does, without closing the sockets. It SHALL return how many it sent, or -1 when nothing could be sent, and then every listener stays active.

#### Scenario: A restart
- **WHEN** an old process exports its listener to a new one, which adopts it
- **THEN** connections made before, during and after the export are accepted by one of the two

#### Scenario: No one receiving
- **WHEN** `export_listeners` is called with a path no process receives on
- **THEN** it returns -1 and the loop's listeners go on accepting

### Requirement: Links stay with the old process
Exporting listeners SHALL NOT affect the loop's open links: they keep their events until they close, so the old process drains them with the core's operations while the new process accepts new ones.

#### Scenario: Draining after export
- **WHEN** the old process has 5 open links when it exports its listener
- **THEN** the 5 links go on receiving and sending until each closes
