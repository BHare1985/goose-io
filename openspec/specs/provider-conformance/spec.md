# provider-conformance Specification

## Purpose

Defines how an event loop is shown to satisfy the I/O contract and how a library is tested against it: one conformance suite written only against the contract, an in-memory event loop for tests without sockets, example libraries that prove composition, and a recorded mapping for each candidate event loop.

## Requirements

### Requirement: The in-memory loop always makes progress
No configuration of the in-memory event loop SHALL make `serve` run without its clock moving towards the time limit. A `tick_ms` or `passes_per_ms` below 1 SHALL be treated as 1. A test that never calls `stop` SHALL therefore end at the time limit, whatever the configuration.

#### Scenario: A tick period of zero
- **WHEN** a test sets `tick_ms` to 0, runs a loop that counts `Tick` events, and stops it from the handler at 50 ms of the loop's clock
- **THEN** `serve` returns, the clock reads at least 50, and the loop delivered no more than one `Tick` per millisecond of that clock

#### Scenario: A negative tick period
- **WHEN** a test sets `tick_ms` to -5 and runs a loop that never calls `stop`, with `exit_on_time_limit` off
- **THEN** `serve` returns once the time limit has passed on the loop's clock and `hit_time_limit` is true

#### Scenario: A pass rate of zero
- **WHEN** a test sets `passes_per_ms` to 0 and two joined links exchange bytes until a handler stops the loop
- **THEN** the loop ends normally

### Requirement: Stopping lets scripted peers finish reading
After `stop`, `serve` SHALL NOT return while a scripted peer's link holds bytes the library has sent that the peer is still going to read, or an end of stream the peer has not yet seen. A peer told to stop reading, and a peer whose later steps are not yet due, SHALL NOT delay `serve`.

#### Scenario: Send, close, stop
- **WHEN** a library sends a reply to a scripted peer, calls `close`, and calls `stop(0)` from the handler of that link's `Closed`
- **THEN** after `serve` returns the test reads the whole reply with `peer_received`, and `peer_saw_eof` is true

#### Scenario: Shutdown instead of close
- **WHEN** a library sends a reply to a scripted peer, calls `shutdown_write`, and calls `stop(0)` from the same handler
- **THEN** after `serve` returns the peer has received the whole reply and `peer_saw_eof` is true, and the library's link still received `Closed` with reason `Shutdown`

#### Scenario: A peer that stopped reading does not hold the loop
- **WHEN** a scripted peer has been told to stop reading, the library has sent it bytes and called `close`, and the library calls `stop(0)`
- **THEN** `serve` returns without waiting for the peer, and `peer_received` holds only what the peer read before it stopped

#### Scenario: A peer with a distant step does not hold the loop
- **WHEN** a scripted peer has a step due ten seconds later, the library has finished with its link, and the library calls `stop(0)`
- **THEN** `serve` returns before that step is due

### Requirement: Listener addresses do not overlap
In the in-memory event loop, `listen` SHALL fail with `AddressInUse` when an active listener or a held address has the same address family and port and either address is the wildcard or the two are equal. A dial SHALL therefore match at most one listener. A stopped listener SHALL NOT conflict, and IPv4 and IPv6 are separate families.

#### Scenario: Wildcard then specific
- **WHEN** a library listens on `0.0.0.0:8080` and then on `127.0.0.1:8080`
- **THEN** the second `listen` returns `AddressInUse` and a dial to `127.0.0.1:8080` opens a link carrying the first listener's tag

#### Scenario: Specific then wildcard
- **WHEN** a library listens on `127.0.0.1:8080` and then on `0.0.0.0:8080`
- **THEN** the second `listen` returns `AddressInUse`

#### Scenario: A held wildcard
- **WHEN** a test holds `0.0.0.0:8080` and a library listens on `127.0.0.1:8080`
- **THEN** `listen` returns `AddressInUse`

#### Scenario: Different ports, families and stopped listeners
- **WHEN** a library listens on `0.0.0.0:8080`, then on `127.0.0.1:8081` and `[::1]:8080`, and stops the first listener and listens on `127.0.0.1:8080`
- **THEN** every one of those `listen` calls succeeds

### Requirement: System-chosen ports are free ports
In the in-memory event loop, `listen` on port zero SHALL choose a port from 49152 to 65535 that no active listener or held address uses, SHALL return a non-zero `listener_port`, and SHALL fail with `NoResources` only when every port in that range is in use. Accepted connections SHALL report a remote port in the same range.

#### Scenario: The next port is taken
- **WHEN** a library listens explicitly on `127.0.0.1:49152` and then listens on `127.0.0.1:0`
- **THEN** the second `listen` succeeds and its `listener_port` is in the range and is not 49152

#### Scenario: Ports do not run out of range
- **WHEN** a loop accepts more than 16384 connections and a library then listens on port zero
- **THEN** `listener_port` is non-zero and at least 49152, and `peer_address` of the last accepted link names a port in the range

#### Scenario: Every port is in use
- **WHEN** every port from 49152 to 65535 on one address is held or listened on and a library listens on port zero there
- **THEN** `listen` returns `NoResources`

### Requirement: The in-memory event loop states its limits
The in-memory event loop SHALL document, and its tests SHALL pin, the bounds a library can observe. `max_links` SHALL count link ends on the loop, so a pair joined inside the loop uses two and a connection to a scripted peer uses one. The address grammar SHALL be `ip:port` for IPv4 and `[ip]:port` for IPv6 with hexadecimal groups; IPv4-embedded IPv6 text SHALL be `BadAddress`.

#### Scenario: A joined pair uses two links
- **WHEN** a loop is configured with `max_links` of 2, one library listens, another dials it, and a third dial is made once both ends are open
- **THEN** the first dial opens on both ends and the third fails with `ConnectFailed`, kind `NoResources`

#### Scenario: A scripted peer's end is not counted
- **WHEN** a loop is configured with `max_links` of 1 and a library dials an address where a scripted peer waits
- **THEN** the dial opens

#### Scenario: IPv4-embedded IPv6 text
- **WHEN** a library dials `[::ffff:192.0.2.1]:80` or listens on `[::ffff:192.0.2.1]:80`
- **THEN** the dial ends with `ConnectFailed`, kind `BadAddress`, and the listen returns `BadAddress`

### Requirement: An event loop in any repository can run the suite
An event loop's author SHALL be able to run the suite for the core, and for each group the loop supplies, from the loop's own repository by importing it and supplying the loop and a small fixture. The fixture SHALL supply only what contract calls cannot produce: an address that never answers, an address that is already held, and an address that nothing listens on.

#### Scenario: Running the suite from outside
- **WHEN** a root program outside the contract package imports the suite, constructs an event loop and passes it with a fixture to the entry point of one group
- **THEN** every check of that group runs against that loop and the program's exit status reports whether all passed

### Requirement: Every check is shown to fail on a broken event loop
For every conformance check there SHALL be a recorded fault that the in-memory event loop can be switched to exhibit, and the check SHALL fail when that fault is on. A check that passes against its fault SHALL be treated as a defect in the suite.

#### Scenario: A fault is detected
- **WHEN** the in-memory event loop is switched to deliver `Data` after `Closed` and the suite is run
- **THEN** the check for link event order fails and names that requirement

#### Scenario: No check is untested
- **WHEN** the list of checks is compared with the list of faults
- **THEN** every check has at least one fault that makes it fail

### Requirement: Failures are never hidden by repetition
The suite SHALL be repeatable on demand, and a check that fails in any repetition SHALL be reported as failed. A check that fails intermittently SHALL be treated as failing until its cause is explained.

#### Scenario: An intermittent failure
- **WHEN** the suite is run fifty times and one check fails once
- **THEN** the run reports that check as failed and keeps the failing output

### Requirement: An in-memory event loop for deterministic tests
The project SHALL ship an event loop that implements the whole contract, the core and every group, in memory, with no sockets and a clock that moves only when the test or the loop advances it. A test SHALL be able to script a peer: connect, accept or refuse a dial, send bytes, stop and resume reading, half-close, close and abort. A test SHALL be able to read what a library sent on each link.

#### Scenario: A library test without a network
- **WHEN** a test scripts a peer that accepts a dial and sends a reply in two parts, and the clock is advanced past a deadline
- **THEN** the library under test observes `Opened`, two `Data` events and the `Tick` in that order, and the test completes without opening a socket or sleeping

#### Scenario: Two links on one loop are joined
- **WHEN** a library listens on an address and another library on the same loop dials it
- **THEN** both links open, and bytes sent on one arrive as `Data` on the other, subject to the same backpressure rules as any link

#### Scenario: The same run twice
- **WHEN** the same test is run twice against the in-memory event loop
- **THEN** both runs deliver the same events in the same order at the same clock times

### Requirement: Example libraries prove composition
The project SHALL ship a small server library and a small client library written only against the contract, and each SHALL say which parts of the contract it needs. The client SHALL need only the core; it SHALL keep a pool of outbound links, pipeline requests, apply a per-request deadline, reconnect with backoff after a lost link, and respect send backpressure. Both SHALL be exercised by tests on the in-memory event loop.

#### Scenario: The client survives a lost link
- **WHEN** a scripted peer aborts a pooled link with requests outstanding
- **THEN** each outstanding request is reported as failed exactly once, and a later request is sent on a new link dialled after the backoff period

#### Scenario: The client shares a loop with a server library
- **WHEN** a program runs the server library and the client library on one loop, and a request to the server is answered using a reply fetched through the client
- **THEN** the request is answered correctly and neither library's source names the other

#### Scenario: A deadline expires
- **WHEN** a scripted peer accepts a request and never replies, and the clock passes the request's deadline
- **THEN** the request is reported as timed out once, and a reply arriving later is discarded without being matched to another request

#### Scenario: A library states what it needs
- **WHEN** the example libraries' sources are inspected
- **THEN** each names the groups of the contract it uses, and a program that builds the client against an event loop that supplies only the core succeeds

### Requirement: Candidate event loops have a recorded mapping
For each planned example event loop and each library the contract claims to fit, the project SHALL record, at a named revision of its source, how every operation and event maps onto it, the core and each group apart. Each row SHALL be marked checked against the source or unverified, and an operation with no workable mapping SHALL be resolved in the contract or recorded as a known gap before the version is published.

#### Scenario: Every operation has a row
- **WHEN** a mapping document is compared with the operations and events of the contract
- **THEN** each has a row, marked as part of the core or of one group

#### Scenario: Unverified points are visible
- **WHEN** a row rests on a claim that was not checked against the event loop's source
- **THEN** the row says so, and the list of unverified rows appears at the top of the mapping

#### Scenario: What a core-only loop costs
- **WHEN** a mapping document is read
- **THEN** it lists the adapter work for the core separately from that for each group, so that the cost of a loop that supplies only the core can be read from it

### Requirement: The suite is run one group at a time
The conformance suite SHALL have one entry point for the core and one for each group of extras, and each SHALL compile and run against an event loop that supplies the core and that group, and nothing else. Every check SHALL belong to exactly one of them: a check of the core SHALL call no operation of a group, and a check of a group SHALL call no operation of another group.

#### Scenario: The core suite on a loop with only the core
- **WHEN** a root program passes an event loop that supplies only the core to the core entry point
- **THEN** the program builds and runs every check of the core, and none of a group

#### Scenario: A group suite
- **WHEN** a root program passes an event loop that supplies the core and the sizing group to the sizing entry point
- **THEN** every check of the sizing group runs against it

#### Scenario: A check that reaches into another group
- **WHEN** the operations a check calls are compared with the group it belongs to
- **THEN** the check calls no operation outside the core and its own group

### Requirement: The conformance suite is event-loop-neutral
The project SHALL ship a conformance suite written only against the I/O contract and generic over the event loop. The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of an event loop, and each check SHALL name the requirement it proves and the group it belongs to.

#### Scenario: Every contract scenario is covered
- **WHEN** the list of `io-contract` scenarios is compared with the suite's checks
- **THEN** each scenario about the behaviour of an event loop has at least one check that names it, and each remaining scenario names the build or inspection step that proves it

#### Scenario: The suite names no event loop
- **WHEN** the suite's sources are inspected
- **THEN** they import the contract and nothing that names a specific event loop

### Requirement: An event loop says which groups it passes
An event loop SHALL be described as conforming to the core only after the core suite passes against it on the operating system it targets, and as supplying a group only after that group's suite passes. Documentation SHALL state, for each event loop, the contract version, the commit at which each of its groups last passed, and the groups it does not supply.

#### Scenario: An event loop that fails a check
- **WHEN** an event loop fails any conformance check of a group
- **THEN** the suite exits with a failure status naming the check, the requirement and the group, and the documentation does not list that group for that loop

#### Scenario: A loop that passes only the core
- **WHEN** an event loop passes the core suite and supplies no group
- **THEN** the documentation lists it as conforming to the core, with no group

### Requirement: The suite is a tool and not a gate
Nothing in the conformance suite SHALL prevent the use of an event loop that passes less than all of it, and a library SHALL need to be tested only on the groups it uses. The suite SHALL report what failed and where, and leave the decision to the person who chooses the loop.

#### Scenario: A library on a loop that passes only some groups
- **WHEN** a library uses only the core and the sizing group, and the loop passes those two
- **THEN** the library is supported on that loop whatever the loop does for the other groups

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
The unix suite SHALL check a listener and a dial on a path with data both ways, the URL spelling reaching the same listener, a path held by a listener under either spelling, a dial to a path nothing listens on, `listener_port` of a path listener, malformed paths (an authority and a doubled slash included), and the longest path. Each check SHALL name its requirement and have a fault of the in-memory event loop that makes it fail.

#### Scenario: Each check has a fault
- **WHEN** the unix group's checks are compared with the in-memory event loop's faults
- **THEN** every check has at least one fault that makes it fail, recorded in the check table

### Requirement: The in-memory event loop supplies the unix group
The in-memory event loop SHALL supply the unix group, treating a path as the name of an endpoint that a listener holds and a dial reaches. Two paths SHALL conflict only when they are equal, whichever of the two spellings each was written in, and a path SHALL never conflict with a numeric address. Scripted peers SHALL be able to wait at a path as they wait at an address.

#### Scenario: A scripted peer at a path
- **WHEN** a test scripts a peer to accept a dial at `unix:/run/db.sock` and a library dials that path
- **THEN** the library observes `Opened`, then the peer's scripted `Data`, and the test reads the bytes the library sent

#### Scenario: Paths conflict only when equal
- **WHEN** a library listens on `unix:/run/a.sock`, then on `unix:/run/b.sock` and on `0.0.0.0:8080`
- **THEN** every `listen` succeeds, and a second `listen` on `unix:/run/a.sock` returns `AddressInUse`

### Requirement: The in-memory event loop can refuse the unix form
The in-memory event loop SHALL be configurable to refuse `unix:/path` and `unix:///path`, reporting `BadAddress` as an event loop that does not supply the group does, so that the refusal can be shown. The core-only event loop of the tests SHALL refuse it.

#### Scenario: A loop configured to refuse the form
- **WHEN** the in-memory event loop is configured to refuse the form and a library dials `unix:/run/a.sock` and listens on it
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`, and `listen` returns an error of kind `BadAddress`

#### Scenario: The core-only loop refuses it
- **WHEN** a library dials `unix:/run/a.sock` on the core-only event loop
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`
