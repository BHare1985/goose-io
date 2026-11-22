## ADDED Requirements

### Requirement: The shared listen capability is named by its parts
The contract SHALL have an optional capability named shared-listen, made of the operation `listen_shared(address) -> Listener, ListenError`. It SHALL have the declaration `supplies_shared_listen`, the query `has_shared_listen` and the compile-time check `require_shared_listen`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `listen_shared` without a compile-time branch is built against an event loop that does not declare shared-listen
- **THEN** the build fails and the error names `supplies_shared_listen` or `listen_shared`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `listen_shared` only in the branch taken when `goose_io::has_shared_listen` is `Supplied` is built against the core-only loop
- **THEN** it builds, and only one loop listens, and the application uses one loop or hands links off

### Requirement: Shared listeners hold one address together
`listen_shared(address)` SHALL behave as `listen` except that it SHALL succeed while other shared listeners, in the same loop or another loop of the process, hold the address. Each connection to the address SHALL be accepted by exactly one shared listener that holds it.

#### Scenario: Two loops on one port
- **WHEN** two loops of one process each call `listen_shared` on the same address
- **THEN** both succeed and every connection is accepted by one of them, never both

### Requirement: Shared and plain listeners conflict
A `listen` on an address that shared listeners hold SHALL fail with `AddressInUse`, and so SHALL a `listen_shared` on an address a plain listener holds. A `listen_shared` on a unix path SHALL fail with `BadAddress`.

#### Scenario: A plain listen after a shared one
- **WHEN** a loop listens shared on an address and another calls `listen` on it
- **THEN** `listen` fails with `AddressInUse`

### Requirement: A stopped shared listener says what it does with waiting connections
When a shared listener is stopped, the other shared listeners SHALL go on accepting. Connections that were waiting to be accepted by the stopped listener MAY be reset by the system. A loop SHALL document whether it moves them to another listener or resets them.

#### Scenario: One loop of several stops
- **WHEN** one of three loops stops its shared listener
- **THEN** new connections are accepted by the other two
