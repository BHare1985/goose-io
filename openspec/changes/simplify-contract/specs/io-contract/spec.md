# Spec Delta

## ADDED Requirements

### Requirement: The contract is a core and groups of extras
The contract SHALL be a core, which every event loop supplies, and five groups of extras: half-close, sizing, abort, inspection and batching. An event loop MAY supply any group. A rule that belongs to a group SHALL bind only an event loop that supplies that group, and a rule of the core SHALL NOT depend on any group.

#### Scenario: A loop that supplies only the core
- **WHEN** an event loop supplies the core and none of the groups
- **THEN** it conforms to the core, and a library that uses only the core runs on it unchanged

#### Scenario: A library uses an extra the loop lacks
- **WHEN** a library that calls `send2` is built against an event loop that does not supply the sizing group
- **THEN** the build fails and the error names `send2`

#### Scenario: An event the loop never delivers
- **WHEN** an event loop does not supply the half-close group
- **THEN** it never delivers `PeerEof`, and a library's handling of `PeerEof` is never run

### Requirement: The core is thirteen operations and five events
The core operations SHALL be `listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `set_user`, `now_ms`, `tick_by`, `serve`, `stop` and `draining`. The core events SHALL be `Opened`, `Data`, `Writable`, `Closed` and `Tick`. `listener_port` and `pause_reading` are in the core because a suite that runs both ends of every link on one loop cannot otherwise reach a system-chosen port or make a peer that does not read.

#### Scenario: The core is enough for a client
- **WHEN** the example line client is built against an event loop that supplies only the core
- **THEN** the build succeeds and the client's tests pass

### Requirement: Each group is named and checked on its own
The groups SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`, `user`) and batching (`PassEnd`). The contract package SHALL offer a compile-time check for the core and for each group that has operations, each naming every operation of its part. Batching has only an event, and so no check.

#### Scenario: The core check
- **WHEN** an event loop's root program calls the core check
- **THEN** it compiles if the loop supplies every operation of the core with the contract's types, and otherwise the error names the first operation that is missing

#### Scenario: A group check
- **WHEN** an event loop that supplies the abort group calls the abort check
- **THEN** it compiles, and an event loop without `reset` calling it gets an error naming `reset`

### Requirement: Three roles: event loop, library, application
The contract SHALL define an event loop (owns the thread and the sockets, delivers events, performs operations), a library (handles events, calls operations) and an application (the program that runs the event loop and passes events to its libraries). A library SHALL depend only on the contract, never on the types of one event loop. No role SHALL be required to store a callback, allocate from a heap, or call through a function pointer.

#### Scenario: A library runs on two event loops unchanged
- **WHEN** the same library source is built with two different conforming event loops that supply what the library uses
- **THEN** both builds succeed with no change to the library source and no adapter code between the library and either loop

#### Scenario: A library imports no event loop
- **WHEN** the example libraries' sources are inspected
- **THEN** they import the contract and nothing that names a specific event loop

### Requirement: What the contract covers
The contract SHALL cover TCP byte streams over IPv4 and IPv6, ticks and deadlines, and running and stopping one loop, and nothing else. Name resolution, TLS, UDP, Unix sockets, files, signals, cross-thread messaging, starting several loops, and joining two links for forwarding SHALL NOT be required of an event loop. Nothing in a group SHALL be required of an event loop that does not supply the group.

#### Scenario: IPv6 is covered
- **WHEN** a library listens on `[::1]` and dials that address
- **THEN** the link opens and carries data as an IPv4 link does

#### Scenario: An event loop without extras conforms to the core
- **WHEN** an event loop implements only the operations and events of the core
- **THEN** it passes the core of the conformance suite

## MODIFIED Requirements

### Requirement: The contract states its version
The contract SHALL publish its version as a major and minor number, 0.2 for this specification. While the major number is zero, a minor increase MAY change or remove behaviour. From major version one, a minor increase SHALL only add. An event loop SHALL state the contract version it conforms to and the groups it supplies.

#### Scenario: A library reads the version
- **WHEN** a program reads the contract's version
- **THEN** it obtains the major and minor numbers of the contract it was built against

### Requirement: Listening
`listen(address, tag)` SHALL start accepting TCP connections and return a listener handle, or an error naming its kind and a loop-specific code. Each accepted connection SHALL produce `Opened` carrying the listener's tag and handle. `listener_port(listener)` SHALL return the bound port, including one the system chose for port zero. An event loop that supplies the inspection group SHALL provide `stop_listening(listener)`, which stops new connections without closing accepted links.

#### Scenario: A connection is accepted
- **WHEN** a library listens on a free port with tag 1 and a peer connects
- **THEN** the handler receives `Opened` with tag 1 and that listener's handle

#### Scenario: The address is taken
- **WHEN** a library listens on a port that is already held exclusively
- **THEN** `listen` returns an error of kind `AddressInUse` with a loop-specific code, and no events follow

#### Scenario: A system-chosen port can be discovered
- **WHEN** a library listens on port zero and asks for the listener's port
- **THEN** it obtains a non-zero port, and a dial to that port on the same address opens a link

#### Scenario: Stopping a listener keeps its links
- **WHEN** a library on an event loop with the inspection group calls `stop_listening` while a link accepted from that listener is open
- **THEN** new connection attempts are no longer accepted and the open link continues to deliver and send data

### Requirement: Listener handles are never reused
A listener handle SHALL identify one listener for the life of its loop: an event loop SHALL NOT give the same handle to a later listener. An operation on the handle of a listener that has stopped, or on a handle the loop never issued, SHALL have no effect, and `listener_port` SHALL return 0 for it. When an event loop has no unused handle left, `listen` SHALL fail with `NoResources`; it SHALL NOT start again from an old handle. A listener SHALL be used only on the loop that created it.

#### Scenario: A stale listener handle cannot reach a newer listener
- **WHEN** a library on an event loop with the inspection group stops a listener, listens again on the same address, and then calls `stop_listening` with the first handle
- **THEN** the second listener has a different handle and keeps accepting connections, and `listener_port` of the first handle returns 0

#### Scenario: Handles run out and do not wrap
- **WHEN** an event loop has issued every listener handle it can
- **THEN** the next `listen` returns an error of kind `NoResources` and no listener

### Requirement: A link reports its peer's address
An event loop that supplies the inspection group SHALL provide `peer_address(link)`, which returns the remote endpoint of an open link as numeric text in the form `dial` accepts, and an empty value for a link that is not open or whose handle is stale. IPv6 text SHALL be lower case with the longest run of two or more zero groups written as `::`. The value SHALL be available from the link's `Opened` event until its `Closed` event has been delivered.

#### Scenario: An accepted link names its peer
- **WHEN** a library dials a listener on the same loop and the listening side asks for the peer address of the accepted link
- **THEN** it obtains numeric text whose address part is the dialling side's address

#### Scenario: A dialled link names its target
- **WHEN** a library dials `127.0.0.1` on a listener's port and asks for the peer address after `Opened`
- **THEN** it obtains that address and port as text

#### Scenario: A closed link has no peer address
- **WHEN** a library asks for the peer address of a link after its `Closed` event
- **THEN** it obtains an empty value

### Requirement: Send backpressure is explicit and bounded
An event loop SHALL bound the bytes it holds unsent for each link. `max_send` SHALL report the largest single send it can ever accept: at least 4096 bytes, and one value for every link of the loop. A larger send SHALL return `TooLarge`. A send that does not fit now SHALL return `Full`. An event loop that supplies the sizing group SHALL also provide `send_room(link)`, which returns the number of bytes a send would accept now, never more than `max_send`, and 0 for a link that is not open or can no longer send.

#### Scenario: An oversized send never fits
- **WHEN** a library sends more than `max_send` bytes in one call
- **THEN** `send` returns `TooLarge` and no `Writable` is delivered for it

#### Scenario: A reader that never reads does not grow memory
- **WHEN** a library keeps offering bytes to a peer that reads nothing, sending only when `send` accepts
- **THEN** the event loop's memory for that link stays within its per-link bound

#### Scenario: No room on a link that cannot send
- **WHEN** a library on an event loop with the sizing group asks for `send_room` of a link before its `Opened`, after `close`, after `shutdown_write`, or with a stale handle
- **THEN** it obtains 0

### Requirement: Closing
`close(link)` SHALL transmit the bytes already accepted and then end the connection cleanly, without waiting for the peer to finish; on a link that has not opened it SHALL cancel the dial. An event loop that supplies the abort group SHALL also provide `reset(link)`, which ends the link at once, discarding unsent bytes, so the peer observes an abort. After either call, sends SHALL return `Closed` and the only further event for the link SHALL be exactly one `Closed` with reason `Local`.

#### Scenario: Close after a reply
- **WHEN** a library sends a reply and immediately calls `close`
- **THEN** the peer receives the whole reply, then end of stream, and the handler receives one `Closed` with reason `Local`

#### Scenario: Nothing but Closed after close
- **WHEN** a library calls `close` on a link that is owed a `Writable` and whose peer has just finished sending
- **THEN** the handler receives one `Closed` with reason `Local` for the link and no `Writable`, `PeerEof` or `Data`

#### Scenario: Cancelling a dial
- **WHEN** a library calls `close` on a dialled link before its `Opened` event
- **THEN** the connection attempt is abandoned, no `Opened` is delivered, and one `Closed` follows

#### Scenario: Reset
- **WHEN** a library on an event loop with the abort group calls `reset` on an open link with bytes still queued
- **THEN** the peer's link ends with reason `PeerReset` and the handler receives one `Closed` with reason `Local` for the reset link

### Requirement: Peer end of stream and half-close
When the peer finishes sending, an event loop SHALL transmit the bytes already accepted and close the link with reason `PeerClosed`; this is the whole of the core's behaviour on the peer's end of stream. An event loop that supplies the half-close group SHALL also provide `set_keep_open_on_eof(link, keep)`, `shutdown_write(link)` and the event `PeerEof`: after `set_keep_open_on_eof(link, true)` it SHALL deliver `PeerEof` once, after every `Data`, and keep the link open for sending; `shutdown_write(link)` SHALL end the local sending direction once accepted bytes are out, later sends SHALL return `Closed`, and the link SHALL close when the peer has finished too.

#### Scenario: Default behaviour on peer end of stream
- **WHEN** a peer sends a request and shuts down its sending side, and the library has not opted in to keep the link open
- **THEN** bytes the library already sent reach the peer and the handler receives `Closed` with reason `PeerClosed`

#### Scenario: Answering after the peer half-closes
- **WHEN** a library on an event loop with the half-close group has opted in, the peer half-closes, and the library then sends a reply and calls `shutdown_write`
- **THEN** the handler receives `PeerEof` once after all `Data`, the peer receives the whole reply followed by end of stream, and `Closed` follows

### Requirement: End-of-pass notification
An event loop MAY supply the batching group. One that does SHALL deliver exactly one `PassEnd` as the last event of every pass that delivered at least one link event: no link event and no `Tick` of that pass SHALL follow it. A pass that delivered only ticks or nothing SHALL have none. Operations called while handling `PassEnd` SHALL behave as anywhere else, and events they cause SHALL NOT produce a second `PassEnd` for the same pass. A library SHALL NOT depend on `PassEnd` for correctness: it is for batching only.

#### Scenario: Batching replies
- **WHEN** ten requests on ten links arrive in one pass on an event loop with the batching group
- **THEN** the handler receives the ten `Data` events and then exactly one `PassEnd`

#### Scenario: PassEnd is last
- **WHEN** one pass delivers a `Tick` and link events on an event loop with the batching group
- **THEN** `PassEnd` is delivered after all of them, and the application offers it to every library once

#### Scenario: An idle pass
- **WHEN** a pass delivers only a `Tick`
- **THEN** no `PassEnd` is delivered

#### Scenario: A loop without batching
- **WHEN** an event loop does not supply the batching group
- **THEN** it never delivers `PassEnd`, and every library that sends as it handles each event still works

### Requirement: The application runs and stops the loop
`serve` SHALL run the loop on the calling thread, delivering events to the application's handler, until the loop has stopped. `stop(grace_ms)` SHALL stop every listener at once and make `draining` true. `serve` SHALL return once no link remains, or after `grace_ms`, when the event loop SHALL close each remaining link with reason `Shutdown` and deliver its `Closed` before returning.

#### Scenario: Stop with nothing open
- **WHEN** a handler calls `stop` while no links are open
- **THEN** no further connections are accepted and `serve` returns without waiting for the grace period

#### Scenario: Stop with a link that stays open
- **WHEN** a handler calls `stop` with a grace period of two seconds while one link stays open
- **THEN** `draining` is true for later handlers, the link receives `Closed` with reason `Shutdown` once two seconds of the loop's clock have passed, and `serve` then returns

#### Scenario: Libraries finish and the loop ends early
- **WHEN** a handler calls `stop` with a grace period and every library closes its links on seeing `draining`
- **THEN** `serve` returns as soon as the last `Closed` has been delivered

### Requirement: Draining is the same on every event loop
After `stop`, `listen` SHALL fail and `dial` SHALL still work; a link opened while draining ends with the same grace period and does not extend it. Of several `stop` calls the earliest end of grace SHALL stand. `serve` and `stop` belong to the application: a library SHALL NOT call them. A loop whose `serve` has returned SHALL NOT be run again.

#### Scenario: Listening while draining
- **WHEN** a library calls `listen` after `stop`
- **THEN** `listen` returns an error and no listener

#### Scenario: Dialling while draining
- **WHEN** a library dials a listening address after `stop` with a grace period, to finish work in hand
- **THEN** the link opens, and if it is still open at the end of the grace period it receives `Closed` with reason `Shutdown`

#### Scenario: Stop called twice
- **WHEN** a handler calls `stop` with a grace period of 300 ms and later calls `stop` with a grace period of five seconds
- **THEN** remaining links are closed with reason `Shutdown` 300 ms after the first call

### Requirement: Event loops can be layered
An event loop SHALL be able to wrap another event loop, transforming the bytes of some or all links, and present the same contract to libraries above it. Nothing in the contract SHALL prevent the wrapper from delaying `Opened`, changing the size of what is sent or received, or closing a link with a loop-specific reason. A wrapper SHALL supply at least the groups it passes through.

#### Scenario: A transforming wrapper conforms
- **WHEN** a wrapper that alters every byte on the way out and restores it on the way in is placed over a conforming event loop
- **THEN** the conformance suite passes against the wrapper for the groups the wrapper supplies, with no change to the suite or to the event loop underneath

#### Scenario: A library cannot tell
- **WHEN** the example client and server libraries run over the wrapper
- **THEN** their tests pass with no change to either library's source

### Requirement: Two parts can be sent as one
An event loop that supplies the sizing group SHALL provide `send2(link, first, second)`, which behaves as one `send` of the two byte ranges joined in that order: both are taken and `Sent` is returned, or neither is taken. Its size for `Full`, `TooLarge` and `send_room` SHALL be the sum of the two lengths.

#### Scenario: A header and a body
- **WHEN** a library calls `send2` with a 20-byte header and a 100-byte body on an open, idle link
- **THEN** `send2` returns `Sent` and the peer receives the 120 bytes in order with nothing between them

#### Scenario: Neither part is taken when both do not fit
- **WHEN** `send_room` is smaller than the two parts together but larger than the first
- **THEN** `send2` returns `Full`, the peer receives none of the first part, and one `Writable` follows once room has opened

## REMOVED Requirements

### Requirement: Three roles, one contract
**Reason**: its scenarios name "providers", and a modified requirement may not rename a scenario; replaced by *Three roles: event loop, library, application*, which says the same with the new words.
**Migration**: use *Three roles: event loop, library, application*.

### Requirement: Scope of the base contract
**Reason**: one of its scenarios names a "provider" without extras, and a modified requirement may not rename a scenario; replaced by *What the contract covers*, which adds that nothing in a group is required of a loop that does not supply it.
**Migration**: use *What the contract covers*.

## RENAMED Requirements

- FROM: `### Requirement: The host runs and stops the loop`
- TO: `### Requirement: The application runs and stops the loop`
- FROM: `### Requirement: Draining is the same on every provider`
- TO: `### Requirement: Draining is the same on every event loop`
- FROM: `### Requirement: Providers can be layered`
- TO: `### Requirement: Event loops can be layered`
