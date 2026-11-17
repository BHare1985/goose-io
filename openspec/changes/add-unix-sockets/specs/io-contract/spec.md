# Spec Delta

## MODIFIED Requirements

### Requirement: The contract exposes no operating-system primitives
Contract types and operations SHALL NOT expose file descriptors, socket address structures, poll masks, or any other operating-system or backend object. Addresses SHALL be text: numeric `ip:port` for IPv4 and `[ip]:port` for IPv6, and, for an event loop that supplies the unix group, `unix:/path`. An IPv6 zone identifier is not part of an address: text that contains one SHALL be treated as malformed.

#### Scenario: A zone identifier is rejected
- **WHEN** a library dials `[fe80::1%eth0]:80`, and listens on it
- **THEN** the dial ends with one `Closed` with reason `ConnectFailed`, and `listen` returns an error of kind `BadAddress`

#### Scenario: An event loop without descriptors conforms
- **WHEN** an event loop that has no file descriptors at all implements the contract in memory
- **THEN** every operation and event of the contract is expressible and the conformance suite runs against it

### Requirement: A failed dial says why
A `ConnectFailed` reason SHALL carry a kind: `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress` or `Other`. An event loop SHALL report `BadAddress` for text that is not an address of a form it accepts (a numeric address, and `unix:/path` where it supplies the unix group), `TimedOut` when `connect_ms` elapses, and `NoResources` when it has no link left. For every other failure it SHALL translate what its system reports, and report `Other` when it cannot tell. No system error number is part of the reason.

#### Scenario: A malformed address or a host name
- **WHEN** a library dials `not an address`, or `db.example.com:5432`
- **THEN** the `Closed` event's reason is `ConnectFailed` with kind `BadAddress`

#### Scenario: A dial that times out says so
- **WHEN** a library dials an address that never answers with `connect_ms` of 200
- **THEN** the `Closed` event's reason is `ConnectFailed` with kind `TimedOut`

#### Scenario: A refused dial
- **WHEN** a library dials an address nothing listens on
- **THEN** the `Closed` event's reason is `ConnectFailed` with kind `Refused`, or `Other` on an event loop that cannot tell a refusal from other failures

#### Scenario: An event loop out of links
- **WHEN** a library dials while the event loop has no link left
- **THEN** `dial` still returns a valid link and its `Closed` event's reason is `ConnectFailed` with kind `NoResources`

#### Scenario: A library handles every kind
- **WHEN** dials fail with each of the kinds in turn
- **THEN** the example client library treats each as a failed dial, reports the kind, and retries a kind it has no special rule for as it retries `Other`

### Requirement: The contract is a core and groups of extras
The contract SHALL be a core, which every event loop supplies, and six groups of extras: half-close, sizing, abort, inspection, batching and unix. An event loop MAY supply any group. A rule that belongs to a group SHALL bind only an event loop that supplies that group, and a rule of the core SHALL NOT depend on any group.

#### Scenario: A loop that supplies only the core
- **WHEN** an event loop supplies the core and none of the groups
- **THEN** it conforms to the core, and a library that uses only the core runs on it unchanged

#### Scenario: A library uses an extra the loop lacks
- **WHEN** a library that calls `send2` is built against an event loop that does not supply the sizing group
- **THEN** the build fails and the error names `send2`

#### Scenario: An event the loop never delivers
- **WHEN** an event loop does not supply the half-close group
- **THEN** it never delivers `PeerEof`, and a library's handling of `PeerEof` is never run

### Requirement: Each group is named and checked on its own
The groups SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`, `user`), batching (`PassEnd`) and unix (the address form `unix:/path`). The contract package SHALL offer a compile-time check for the core and for each group that has operations, each naming every operation of its part. Batching has only an event, and unix has only an address form, and so neither has a check.

#### Scenario: The core check
- **WHEN** an event loop's root program calls the core check
- **THEN** it compiles if the loop supplies every operation of the core with the contract's types, and otherwise the error names the first operation that is missing

#### Scenario: A group check
- **WHEN** an event loop that supplies the abort group calls the abort check
- **THEN** it compiles, and an event loop without `reset` calling it gets an error naming `reset`

### Requirement: What the contract covers
The contract SHALL cover TCP byte streams over IPv4 and IPv6, stream sockets at a path in the unix group, ticks and deadlines, and running and stopping one loop, and nothing else. Name resolution, TLS, UDP, files, signals, cross-thread messaging, starting several loops, and joining two links for forwarding SHALL NOT be required of an event loop. Nothing in a group SHALL be required of an event loop that does not supply the group.

#### Scenario: IPv6 is covered
- **WHEN** a library listens on `[::1]` and dials that address
- **THEN** the link opens and carries data as an IPv4 link does

#### Scenario: An event loop without extras conforms to the core
- **WHEN** an event loop implements only the operations and events of the core
- **THEN** it passes the core of the conformance suite

## ADDED Requirements

### Requirement: The unix group is the address form unix:/path
An event loop that supplies the unix group SHALL accept `unix:/path` in `listen` and `dial`, naming a connection-oriented stream socket, with the same operations, events, results and rules as for a TCP address. The group SHALL add no operation, event or type. An event loop that does not supply it SHALL treat the text as any address it does not accept: `listen` returns an error of kind `BadAddress`, and `dial` ends with one `Closed` of reason `ConnectFailed` with kind `BadAddress`.

#### Scenario: A listener and a dial on a path
- **WHEN** a library on an event loop that supplies the unix group calls `listen("unix:/run/x.sock", tag)` and the same loop calls `dial("unix:/run/x.sock", tag2, 0)`
- **THEN** the listen succeeds, both links receive `Opened` (the accepted one with the listener's tag and handle, the dialled one with no listener), and bytes sent on one arrive on the other in order

#### Scenario: A loop without the group
- **WHEN** a library calls `dial("unix:/run/x.sock", tag, 0)` or `listen("unix:/run/x.sock", tag)` on an event loop that does not supply the unix group
- **THEN** the dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress` and no `Opened`, and `listen` returns an error of kind `BadAddress`

### Requirement: A Unix socket path is absolute and bounded
A Unix socket address SHALL be malformed, and so reported as `BadAddress`, when its path is empty, is not absolute, is longer than 103 bytes, holds a NUL byte, or begins with `@` as an abstract name would. An event loop SHALL NOT resolve or normalise a path.

#### Scenario: Malformed paths
- **WHEN** a library on an event loop that supplies the unix group dials `unix:`, `unix:run/x.sock`, `unix:@name`, and a `unix:` address whose path is 104 bytes long
- **THEN** each dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress`

#### Scenario: The longest path
- **WHEN** a library on an event loop that supplies the unix group listens on a path of 103 bytes and dials it
- **THEN** both links receive `Opened`

### Requirement: A Unix path is held by one listener and has no port
`listen` on a Unix path that an active listener of the same event loop holds SHALL fail with `AddressInUse`, and the path SHALL be free again once its listener is stopped. `listener_port` SHALL return 0 for a listener on a Unix path. A dial to a path nothing listens on SHALL end with `ConnectFailed` of kind `Refused`.

#### Scenario: The path is held
- **WHEN** a library listens on a Unix path that a listener on the same loop holds
- **THEN** `listen` returns an error of kind `AddressInUse` and no events follow

#### Scenario: No port
- **WHEN** a library listens on a Unix path and asks `listener_port`
- **THEN** it obtains 0

#### Scenario: Nothing listens on the path
- **WHEN** a library dials a Unix path nothing listens on
- **THEN** the dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `Refused` and no `Opened`

### Requirement: A Unix link has no peer address text
An event loop that supplies both the unix and the inspection groups SHALL return the empty value from `peer_address` for any link made on a Unix path, because `Address` holds a numeric endpoint of at most 56 bytes and the peer of an accepted Unix connection has no name.

#### Scenario: No peer text
- **WHEN** a library on such an event loop listens on a Unix path, dials it, and asks `peer_address` of both links after `Opened`
- **THEN** each value is empty
