## ADDED Requirements

### Requirement: The name resolution capability is named by its parts
The contract SHALL have an optional capability named name-resolution, made of the operations `resolve`, `resolved_address` and `cancel_resolve`, the event `Resolved`, and the types `Query` and `ResolveStatus`. It SHALL have the declaration `supplies_name_resolution`, the query `has_name_resolution` and the compile-time check `require_name_resolution`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `resolve` without a compile-time branch is built against an event loop that does not declare name-resolution
- **THEN** the build fails and the error names `supplies_name_resolution` or `resolve`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `resolve` only in the branch taken when `goose_io::has_name_resolution` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it runs `getaddrinfo` on a thread of its own and receives the addresses through `wake_with`

### Requirement: A lookup ends in one Resolved
`resolve(host, port, timeout_ms)` SHALL return a valid `Query` and deliver exactly one `Resolved` for it, unless it is cancelled, with `status` and `count`. `count` SHALL be above 0 only for `Found`. An empty host, a port outside 0 to 65535, or a finished loop SHALL return an invalid query and deliver nothing.

#### Scenario: A name that exists
- **WHEN** a library resolves a name the system knows
- **THEN** it receives one `Resolved` with `Found` and a count of at least 1

#### Scenario: A name that does not
- **WHEN** a library resolves a name with no addresses
- **THEN** it receives one `Resolved` with `NotFound` and count 0

### Requirement: Resolved addresses are valid while the event is handled
While a `Resolved` with `Found` is handled, `resolved_address(query, i)` for `i` from 0 to `count - 1` SHALL return an address `dial` accepts, with the port given to `resolve`, in the order a client should try them. Outside that handler, or for another `i`, it SHALL return an empty address.

#### Scenario: Dialling a result
- **WHEN** a library dials `resolved_address(query, 0)` in the `Resolved` handler
- **THEN** the dial is to the first address of the result on the given port

#### Scenario: After the handler
- **WHEN** a library calls `resolved_address` in a later pass
- **THEN** it returns an empty address

### Requirement: A lookup is bounded and can be cancelled
A lookup with no result after `timeout_ms` SHALL end with `TimedOut`. `cancel_resolve(query)` SHALL end a lookup with no `Resolved` after it. A lookup still running when the loop finishes SHALL end with `Cancelled` before the loop's last pass.

#### Scenario: A slow name
- **WHEN** a scripted name answers after 5000 ms and the timeout is 1000 ms
- **THEN** `Resolved` arrives with `TimedOut` at 1000 ms on the loop's clock

#### Scenario: A cancelled lookup
- **WHEN** a library cancels a query before its result
- **THEN** no `Resolved` is delivered for it

### Requirement: Dial still takes only addresses
Supplying name resolution SHALL NOT change `dial`: a host name given to `dial` SHALL still close with `ConnectFailed`, `BadAddress`, so resolving is always a step the library asks for.

#### Scenario: A host name to dial
- **WHEN** a library dials `example.test:80` on a loop that supplies name resolution
- **THEN** the link gets `Closed` with `ConnectFailed`, `BadAddress`
