## ADDED Requirements

### Requirement: A capability's suite requires its declaration
The entry point of a capability's suite SHALL build only against a loop that declares the capability, so that a loop cannot pass a capability's suite without saying it supplies it. The suite of the core SHALL require no declaration.

#### Scenario: A loop that does not declare peek
- **WHEN** a root program passes a loop that has every operation of peek but does not declare peek to the peek entry point
- **THEN** the program fails to build and the error names the peek declaration

### Requirement: Optional use is tested on loops with and without the capability
Every example library that uses a capability optionally SHALL be tested on a loop that supplies the capability and on a loop that does not, and both runs SHALL pass the same tests of what the library's peers observe.

#### Scenario: The forwarder on two loops
- **WHEN** the forwarder's tests run on the in-memory loop and on the core-only loop
- **THEN** both pass, and only the test that counts `Data` events tells them apart

### Requirement: The suite is run one capability at a time
The conformance suite SHALL have one entry point for the core and one for each capability, and each SHALL compile and run against an event loop that supplies the core and that capability, and nothing else. Every check SHALL belong to exactly one of them: a check of the core SHALL call no operation of a capability, and a check of a capability SHALL call no operation of another capability.

#### Scenario: The core suite on a loop with only the core
- **WHEN** a root program passes an event loop that supplies only the core to the core entry point
- **THEN** the program builds and runs every check of the core, and none of a capability

#### Scenario: A capability suite
- **WHEN** a root program passes an event loop that supplies the core and the sizing capability to the sizing entry point
- **THEN** every check of the sizing capability runs against it

#### Scenario: A check that reaches into another capability
- **WHEN** the operations a check calls are compared with the capability it belongs to
- **THEN** the check calls no operation outside the core and its own capability

### Requirement: An event loop says which capabilities it passes
An event loop SHALL be described as conforming to the core only after the core suite passes against it on the operating system it targets, and as supplying a capability only after it declares the capability and that capability's suite passes. Documentation SHALL state, for each event loop, the contract version, the commit at which each of its capabilities last passed, and the capabilities it does not supply. These SHALL be the capabilities its declarations name.

#### Scenario: An event loop that fails a check
- **WHEN** an event loop fails any conformance check of a capability
- **THEN** the suite exits with a failure status naming the check, the requirement and the capability, and the documentation does not list that capability for that loop

#### Scenario: A loop that passes only the core
- **WHEN** an event loop passes the core suite and supplies no capability
- **THEN** the documentation lists it as conforming to the core, with no capability

#### Scenario: Documentation and declarations agree
- **WHEN** the capabilities listed for the in-memory loop in the documentation are compared with the capabilities it declares
- **THEN** the two lists are the same, and the inspection fails and names the difference when they are not

### Requirement: The suite is a tool, not a gate
Nothing in the conformance suite SHALL prevent the use of an event loop that passes less than all of it, and a library SHALL need to be tested only on the capabilities it uses. The suite SHALL report what failed and where, and leave the decision to the person who chooses the loop.

#### Scenario: A library on a loop that passes only some capabilities
- **WHEN** a library uses only the core and the sizing capability, and the loop passes those two
- **THEN** the library is supported on that loop whatever the loop does for the other capabilities

### Requirement: The unix capability has its own suite
The conformance suite SHALL have an entry point for the unix capability, run against an event loop that supplies the core and that capability. The fixture SHALL supply one absolute path at which the event loop may create a socket, and every other path a check needs SHALL be derived from it. A check of the capability SHALL call no operation of another capability, `peer_address` included.

#### Scenario: A loop that supplies the capability
- **WHEN** a root program passes an event loop that supplies the core and the unix capability, and a fixture with a path, to the unix entry point
- **THEN** every check of the capability runs against it, and the program's exit status says whether all passed

#### Scenario: A check that reaches into another capability
- **WHEN** the operations the unix capability's checks call are compared with the capabilities they belong to
- **THEN** no check calls an operation of a capability other than the core

#### Scenario: A loop that does not supply the capability
- **WHEN** an event loop that supplies only the core is built
- **THEN** it builds and passes the core suite, and the unix suite is not run against it

### Requirement: The suite checks each link operation in every state
The suite SHALL check the result of each link operation in each link state that the scenarios of `io-contract` name: core operations in the core suite, and each capability's operations in that capability's suite. The batching and unix capabilities have no link operation and SHALL have no such check. The suite SHALL check that a `Closed` send result is final, the keep-open window, and how operations complete. Each check SHALL have a fault of the in-memory event loop that makes it fail.

#### Scenario: A loop that ignores a pause before Opened fails
- **WHEN** the in-memory event loop is made to forget a `pause_reading` call made on a dialling link
- **THEN** the check of pausing before `Opened` fails and names its requirement

#### Scenario: A loop that closes twice fails
- **WHEN** the in-memory event loop is made to deliver a second `Closed` for a second `close` on a closing link
- **THEN** the check of closing twice fails

#### Scenario: A loop that wakes a link after a Closed result fails
- **WHEN** the in-memory event loop is made to deliver a `Writable` owed to a link after `send` has returned `Closed` on it
- **THEN** the check that a `Closed` result is final fails

#### Scenario: A loop that honours a late keep-open fails
- **WHEN** the in-memory event loop is made to apply `set_keep_open_on_eof` called after the link's `Opened` handler has returned
- **THEN** the check of the keep-open window fails

#### Scenario: A loop that forgets a closing link's address fails
- **WHEN** the in-memory event loop is made to return an empty `peer_address` once `close` has been called on a link
- **THEN** the inspection capability's check of link states fails

#### Scenario: Capability operations stay in their capability
- **WHEN** the operations called by the new checks are compared with the capabilities the checks belong to
- **THEN** each check calls no operation outside the core and its own capability

### Requirement: Each new capability has its own suite
The conformance suite SHALL have an entry point for each of the relay, peek, revoke, wake and limits capabilities, each compiling and running against a loop that supplies the core and that capability and nothing else. Every check of a capability SHALL call no operation of another capability.

#### Scenario: A capability suite on a loop that supplies only it
- **WHEN** a root program passes a loop that supplies the core and the peek capability to the peek entry point
- **THEN** the program builds and runs every check of the peek capability and none of another capability

#### Scenario: A check that reaches into another capability
- **WHEN** the operations a check of the relay capability calls are compared with the capabilities of the contract
- **THEN** it calls only core operations and operations of the relay capability

### Requirement: Every scenario of a new capability has a check
The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of one of the new capabilities, each naming the requirement it proves. A scenario that needs two capabilities together (a write deadline on a relayed link) SHALL be checked by a test of this repository that supplies both, and not by a capability's entry point.

#### Scenario: Every new scenario is covered
- **WHEN** the scenarios of the new capabilities in `io-contract` are compared with the suite's checks
- **THEN** each has at least one check that names it, or names the build or inspection step that proves it

#### Scenario: Two capabilities together
- **WHEN** a scenario needs the revoke and relay capabilities at once
- **THEN** a test of this repository that supplies both checks it

### Requirement: The in-memory loop supplies every new capability
The in-memory loop SHALL supply the relay, peek, revoke, wake and limits capabilities, with scripted peers able to send, end, reset and not read, so that each capability's suite runs against it with a virtual clock and no network. It SHALL be able to bound each capability's buffers by configuration, as it bounds links and buffers now. 

#### Scenario: The suite of a new capability runs in memory
- **WHEN** the relay suite is run against the in-memory loop
- **THEN** every check passes, and a repetition produces the same output as the first

#### Scenario: A thread wakes the in-memory loop
- **WHEN** a test thread calls `wake` on the in-memory loop's waker during `serve`
- **THEN** `Woken` is delivered on the loop's thread

### Requirement: A loop on a real system passes the new capabilities
An event loop that supplies a new capability on real sockets SHALL pass that capability's suite on the system it targets, in fifty repetitions with no failure, before documentation lists it for that capability, and SHALL hold the system-call, throughput and memory numbers of its own gates with the capability present and unused.

#### Scenario: The epoll ext loop passes the relay suite
- **WHEN** the relay suite is run fifty times against `goose-io-epoll-ext`
- **THEN** every repetition passes, and the loop is listed for relay with the commit at which it passed

#### Scenario: A capability that is not supplied is not listed
- **WHEN** a loop has not passed a capability's suite
- **THEN** the documentation lists the capability under the capabilities it does not supply

## MODIFIED Requirements

### Requirement: The in-memory event loop states its limits
The in-memory event loop SHALL document, and its tests SHALL pin, the bounds a library can observe. `max_links` SHALL count link ends on the loop, so a pair joined inside the loop uses two and a connection to a scripted peer uses one. The address grammar SHALL be `ip:port` for IPv4 and `[ip]:port` for IPv6 with hexadecimal capabilities; IPv4-embedded IPv6 text SHALL be `BadAddress`.

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
An event loop's author SHALL be able to run the suite for the core, and for each capability the loop supplies, from the loop's own repository by importing it and supplying the loop and a small fixture. The fixture SHALL supply only what contract calls cannot produce: an address that never answers, an address that is already held, and an address that nothing listens on.

#### Scenario: Running the suite from outside
- **WHEN** a root program outside the contract package imports the suite, constructs an event loop and passes it with a fixture to the entry point of one capability
- **THEN** every check of that capability runs against that loop and the program's exit status reports whether all passed

### Requirement: An in-memory event loop for deterministic tests
The project SHALL ship an event loop that implements the whole contract, the core and every capability, in memory, with no sockets and a clock that moves only when the test or the loop advances it. A test SHALL be able to script a peer: connect, accept or refuse a dial, send bytes, stop and resume reading, half-close, close and abort. A test SHALL be able to read what a library sent on each link.

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
- **THEN** each names the capabilities of the contract it uses, and a program that builds the client against an event loop that supplies only the core succeeds

### Requirement: Candidate event loops have a recorded mapping
For each planned example event loop and each library the contract claims to fit, the project SHALL record, at a named revision of its source, how every operation and event maps onto it, the core and each capability apart. Each row SHALL be marked checked against the source or unverified, and an operation with no workable mapping SHALL be resolved in the contract or recorded as a known gap before the version is published.

#### Scenario: Every operation has a row
- **WHEN** a mapping document is compared with the operations and events of the contract
- **THEN** each has a row, marked as part of the core or of one capability

#### Scenario: Unverified points are visible
- **WHEN** a row rests on a claim that was not checked against the event loop's source
- **THEN** the row says so, and the list of unverified rows appears at the top of the mapping

#### Scenario: What a core-only loop costs
- **WHEN** a mapping document is read
- **THEN** it lists the adapter work for the core separately from that for each capability, so that the cost of a loop that supplies only the core can be read from it

### Requirement: The conformance suite is event-loop-neutral
The project SHALL ship a conformance suite written only against the I/O contract and generic over the event loop. The suite SHALL contain at least one check for every scenario of the `io-contract` capability that describes the behaviour of an event loop, and each check SHALL name the requirement it proves and the capability it belongs to.

#### Scenario: Every contract scenario is covered
- **WHEN** the list of `io-contract` scenarios is compared with the suite's checks
- **THEN** each scenario about the behaviour of an event loop has at least one check that names it, and each remaining scenario names the build or inspection step that proves it

#### Scenario: The suite names no event loop
- **WHEN** the suite's sources are inspected
- **THEN** they import the contract and nothing that names a specific event loop

### Requirement: The unix suite checks the form's behaviour
The unix suite SHALL check a listener and a dial on a path with data both ways, the URL spelling reaching the same listener, a path held by a listener under either spelling, a dial to a path nothing listens on, `listener_port` of a path listener, malformed paths (an authority and a doubled slash included), and the longest path. Each check SHALL name its requirement and have a fault of the in-memory event loop that makes it fail.

#### Scenario: Each check has a fault
- **WHEN** the unix capability's checks are compared with the in-memory event loop's faults
- **THEN** every check has at least one fault that makes it fail, recorded in the check table

### Requirement: The in-memory event loop supplies the unix capability
The in-memory event loop SHALL supply the unix capability, treating a path as the name of an endpoint that a listener holds and a dial reaches. Two paths SHALL conflict only when they are equal, whichever of the two spellings each was written in, and a path SHALL never conflict with a numeric address. Scripted peers SHALL be able to wait at a path as they wait at an address.

#### Scenario: A scripted peer at a path
- **WHEN** a test scripts a peer to accept a dial at `unix:/run/db.sock` and a library dials that path
- **THEN** the library observes `Opened`, then the peer's scripted `Data`, and the test reads the bytes the library sent

#### Scenario: Paths conflict only when equal
- **WHEN** a library listens on `unix:/run/a.sock`, then on `unix:/run/b.sock` and on `0.0.0.0:8080`
- **THEN** every `listen` succeeds, and a second `listen` on `unix:/run/a.sock` returns `AddressInUse`

### Requirement: The in-memory event loop can refuse the unix form
The in-memory event loop SHALL be configurable to refuse `unix:/path` and `unix:///path`, reporting `BadAddress` as an event loop that does not supply the capability does, so that the refusal can be shown. The core-only event loop of the tests SHALL refuse it.

#### Scenario: A loop configured to refuse the form
- **WHEN** the in-memory event loop is configured to refuse the form and a library dials `unix:/run/a.sock` and listens on it
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`, and `listen` returns an error of kind `BadAddress`

#### Scenario: The core-only loop refuses it
- **WHEN** a library dials `unix:/run/a.sock` on the core-only event loop
- **THEN** the dial ends with one `Closed` with `ConnectFailed` of kind `BadAddress`

### Requirement: The suite checks how handles are issued
In every part of every capability's suite, the driver SHALL record each link handle it is given. The handle `dial` returns and the same handle in that link's `Opened` count as one issuance. The driver SHALL fail `handles_pair_unique` when a pair is issued again or has generation 0. It SHALL fail `handles_slot_held` when a slot is issued while the `Closed` of its previous link is still to be delivered.

#### Scenario: A loop that does not advance the generation fails
- **WHEN** the in-memory event loop is made to reuse a slot without changing its generation
- **THEN** `handles_pair_unique` fails, naming the slot and the generation issued twice

#### Scenario: A loop that reuses a slot early fails
- **WHEN** the in-memory event loop is made to free a slot when `close` is called, before that link's `Closed` is delivered, while still advancing the generation
- **THEN** `handles_slot_held` fails and `handles_pair_unique` does not

#### Scenario: A dialled link seen twice is one issuance
- **WHEN** a check dials a link and later receives that link's `Opened`
- **THEN** neither handle check fails

### Requirement: The suite checks the life of a loop
Every entry point SHALL listen and dial before it calls `serve`, and SHALL check that the events of those calls arrive from `serve`. In a part that calls `stop`, once `serve` has returned, it SHALL check what the operations of its capability do on the finished loop, including that `dial` returns the invalid link, and that a second `serve` returns at once. The core suite SHALL check that a link closed before the end of the grace period ends with `Local`, whether it was closed before or after `stop`.

#### Scenario: A loop that accepts sends after serve fails
- **WHEN** the in-memory event loop is made to return `Sent` from `send` once `serve` has returned
- **THEN** the finished-loop check fails

#### Scenario: A loop that issues a link after serve fails
- **WHEN** the in-memory event loop is made to return a valid link from `dial` once `serve` has returned
- **THEN** the finished-loop check fails

#### Scenario: A loop that runs again fails
- **WHEN** the in-memory event loop is made to deliver a `Tick` from a second `serve`
- **THEN** the finished-loop check fails

#### Scenario: A loop that overrides Local with Shutdown fails
- **WHEN** the in-memory event loop is made to keep a closed link whose peer has not read until the end of the grace period, and to end it with `Shutdown`
- **THEN** the check of the end of the grace period fails for the link closed before `stop` and for the link closed after it

### Requirement: Every check of a new capability is shown to fail
For every check of the new capabilities the in-memory loop SHALL have a named fault that makes the check fail, and the fault script SHALL show it, so that a check that passes against its own fault is reported as a defect in the suite.

#### Scenario: A relay that drops a byte
- **WHEN** the in-memory loop is switched to the fault in which `relay` drops the last byte of a message
- **THEN** the relay check of intact bytes fails and names the requirement

#### Scenario: A write deadline that is read at the start of the pass
- **WHEN** the loop is switched to the fault in which a write deadline is compared with the clock at the start of the pass and not at the write
- **THEN** the check that no byte is written after the deadline fails

#### Scenario: A limit that counts from arming
- **WHEN** the loop is switched to the fault in which an idle limit is measured from the call and not from the last byte, or the fault in which `Stalled` also runs while nothing waits to be sent
- **THEN** the check that activity moves the due time fails, or the check that nothing waiting never expires fails

#### Scenario: A check with no fault
- **WHEN** the table of checks is compared with the table of faults
- **THEN** every check of a new capability names a fault, and the table check fails when one does not

## REMOVED Requirements

### Requirement: The suite is run one group at a time
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The suite is run one capability at a time`.

### Requirement: An event loop says which groups it passes
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `An event loop says which capabilities it passes`.

### Requirement: The suite is a tool and not a gate
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The suite is a tool, not a gate`.

### Requirement: The unix group has its own suite
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The unix capability has its own suite`.

### Requirement: The suite checks every link operation in every state
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The suite checks each link operation in every state`.

### Requirement: Each new group has its own suite
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `Each new capability has its own suite`.

### Requirement: Every scenario of a new group has a check
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `Every scenario of a new capability has a check`.

### Requirement: The in-memory loop supplies every new group
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The in-memory loop supplies every new capability`.

### Requirement: A loop on a real system passes the new groups
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `A loop on a real system passes the new capabilities`.

## RENAMED Requirements

- FROM: `### Requirement: The in-memory event loop supplies the unix group`
- TO: `### Requirement: The in-memory event loop supplies the unix capability`
- FROM: `### Requirement: Every check of a new group is shown to fail`
- TO: `### Requirement: Every check of a new capability is shown to fail`
