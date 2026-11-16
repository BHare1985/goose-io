# io-contract Specification

## Purpose

Defines the event loop-neutral contract between an event loop (an event loop) and the libraries and application that run on it, so an async client or server library written once runs on any conforming event loop, whether that event loop is built on readiness (epoll, kqueue) or completion (io_uring, IOCP).

## Requirements

### Requirement: A refused send is always resolved
After a `send` or `send2` on a link has returned `Full`, the link SHALL receive one `Writable` or its `Closed`; it SHALL NOT stay open and silent for ever. A `Writable` SHALL NOT be delivered for a link whose sending has ended by `shutdown_write`, `close` or `reset`, including one the event loop had already queued. Which of `Writable` or `Closed` an event loop gives when the peer goes away is the event loop's choice.

#### Scenario: The write side is shut while a Writable is owed
- **WHEN** a library has been refused with `Full`, the peer reads enough that a `Writable` is owed, and a handler calls `shutdown_write` on the link before that `Writable` is delivered
- **THEN** no `Writable` is delivered for the link, `send` returns `Closed`, and the link still delivers `Data` and `PeerEof` from the peer

#### Scenario: The write side is shut after a refusal
- **WHEN** a library has been refused with `Full` and then calls `shutdown_write` before the peer reads anything
- **THEN** no `Writable` is delivered for the link, even when the peer later reads everything

#### Scenario: The peer closes while a send is refused
- **WHEN** a library has opted in with `set_keep_open_on_eof(link, true)`, has been refused with `Full` because the peer never read, and the peer then closes its end
- **THEN** the link receives one `Writable` or its `Closed` after the peer's close, and does not stay open with neither

#### Scenario: The retry after the peer is gone
- **WHEN** the link of the previous scenario received `Writable` and the library sends again
- **THEN** `send` returns `Sent` or `Closed`, never `Full`, and the link then ends with `Closed`

### Requirement: The contract package is pure Goose
The contract package SHALL consist of Goose source only: no C sources, no `extern` declarations and no build sidecar. Importing it SHALL add no native code to a program. The package SHALL check cleanly with the supported Goose toolchain.

#### Scenario: The package checks cleanly
- **WHEN** the package entry file is checked with the supported Goose toolchain
- **THEN** the check reports no errors

#### Scenario: Nothing native is pulled in
- **WHEN** the package's files are searched for C sources, `extern` declarations and a build sidecar
- **THEN** none are found

### Requirement: The contract exposes no operating-system primitives
Contract types and operations SHALL NOT expose file descriptors, socket address structures, poll masks, or any other operating-system or backend object. Addresses SHALL be numeric text: `ip:port` for IPv4 and `[ip]:port` for IPv6. An IPv6 zone identifier is not part of an address: text that contains one SHALL be treated as malformed.

#### Scenario: A zone identifier is rejected
- **WHEN** a library dials `[fe80::1%eth0]:80`, and listens on it
- **THEN** the dial ends with one `Closed` with reason `ConnectFailed`, and `listen` returns an error of kind `BadAddress`

#### Scenario: An event loop without descriptors conforms
- **WHEN** an event loop that has no file descriptors at all implements the contract in memory
- **THEN** every operation and event of the contract is expressible and the conformance suite runs against it

### Requirement: The contract states its version
The contract SHALL publish its version as a major and minor number, 0.1 for this specification. While the major number is zero, a minor increase MAY change or remove behaviour. From major version one, a minor increase SHALL only add. An event loop SHALL state the contract version it conforms to and the groups it supplies.

#### Scenario: A library reads the version
- **WHEN** a program reads the contract's version
- **THEN** it obtains the major and minor numbers of the contract it was built against

### Requirement: Links are generation-checked handles
A link SHALL be a fixed-size handle made of a slot and a generation, valid from the call or event that created it until its `Closed` event has been delivered. An operation on a link whose generation no longer matches SHALL affect no other link and SHALL report the link as closed where it returns a status. A link SHALL be used only on the loop that created it.

#### Scenario: A stale handle cannot reach a reused slot
- **WHEN** a link is closed, its slot is reused by a new link, and a library then calls `send`, `close`, `set_user` or `pause_reading` with the old handle
- **THEN** the new link is unaffected, no bytes are sent on it, and `send` returns `Closed`

#### Scenario: The handle is still valid while Closed is handled
- **WHEN** a handler receives `Closed` for a link and calls `user` and `peer_address` with that link before returning
- **THEN** it obtains the link's user value and peer address, and the same calls made after the handler has returned obtain 0 and an empty value

#### Scenario: An unset handle is recognisably invalid
- **WHEN** a library holds a default-constructed link and asks whether it is valid
- **THEN** the answer is no, and every operation on it has no effect

### Requirement: Events are delivered to one handler, one at a time
An event loop SHALL deliver every event of a loop to the single handler the application supplied, on that loop's thread, one event at a time. An event loop SHALL NOT deliver an event from inside a contract operation: an event caused by an operation called during a handler SHALL be delivered after that handler returns. Operations SHALL be called only on that thread.

#### Scenario: A close does not re-enter the handler
- **WHEN** a handler calls `close` on an open link
- **THEN** `close` returns before that link's `Closed` event is delivered, and the event arrives as a later, separate delivery

#### Scenario: A send that closes the link does not re-enter the handler
- **WHEN** a handler calls `send` on a link whose peer has reset the connection
- **THEN** `send` returns before any `Closed` event is delivered, and the `Closed` event arrives as a later, separate delivery

### Requirement: Link events follow a fixed order
For each link an event loop SHALL deliver at most one `Opened`, before any other event of that link; `Data` events in the order the bytes arrived; at most one `PeerEof`, after every `Data`; and exactly one `Closed`, after which no event for that link is delivered.

#### Scenario: An accepted link
- **WHEN** a peer connects, sends two messages and disconnects
- **THEN** the handler sees `Opened`, then `Data` events carrying the bytes in order, then `Closed`, and nothing further for that link

#### Scenario: A link that never opens
- **WHEN** a dial fails for any reason
- **THEN** the handler sees exactly one `Closed` for that link and never an `Opened`

### Requirement: Every link event names its owner
Every link event SHALL carry the link, the 16-bit tag given when the link was dialled or its listener was created, and the 32-bit user value last set for the link (zero until set). The application assigns tags to libraries; a library SHALL treat an event whose tag is not its own as not handled. `Tick` and `PassEnd` carry no tag and SHALL be offered to every library.

#### Scenario: Two libraries share one loop
- **WHEN** a server library with tag 1 and a client library with tag 2 run on the same loop and a `Data` event arrives for a link dialled with tag 2
- **THEN** the event carries tag 2, the server library reports it as not handled, and the client library handles it

#### Scenario: The user value comes back
- **WHEN** a library calls `set_user(link, 41)` and bytes later arrive on that link
- **THEN** the `Data` event carries user value 41

#### Scenario: The user value survives an immediate dial failure
- **WHEN** a library dials a malformed address, calls `set_user(link, 7)` on the returned link before its handler returns, and the failure is then delivered
- **THEN** the `Closed` event carries user value 7

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

### Requirement: Dialling never blocks and always ends in one event
`dial(address, tag, connect_ms)` SHALL start an outbound TCP connection and return a valid link at once. An event loop SHALL NOT resolve host names. The outcome SHALL be `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed, the connection is refused or unreachable, the event loop is out of resources, or `connect_ms` elapses. A `connect_ms` of zero SHALL mean the event loop's default.

#### Scenario: A successful dial
- **WHEN** a library dials a listening address
- **THEN** `dial` returns at once, and an `Opened` event for that link follows

#### Scenario: A refused dial
- **WHEN** a library dials an address nothing listens on
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows and no `Opened`

#### Scenario: A dial that times out
- **WHEN** a library dials an address that never answers with `connect_ms` of 200
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows no earlier than 200 ms after the dial

#### Scenario: A host name is rejected, not resolved
- **WHEN** a library dials `db.example.com:5432`
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows and no name lookup is performed

### Requirement: A failed dial says why
A `ConnectFailed` reason SHALL carry a kind: `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress` or `Other`. An event loop SHALL report `BadAddress` for text that is not a numeric address, `TimedOut` when `connect_ms` elapses, and `NoResources` when it has no link left. For every other failure it SHALL translate what its system reports, and report `Other` when it cannot tell. No system error number is part of the reason.

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

### Requirement: Received bytes are lent for the duration of the event
A `Data` event SHALL carry a read-only slice of bytes owned by the event loop and valid only until the handler returns. An event loop SHALL have at most one undelivered `Data` event per link and SHALL NOT read further from that link until the handler has returned from it.

#### Scenario: Bytes arrive as a slice
- **WHEN** a peer sends 100 bytes
- **THEN** the handler receives one or more `Data` events whose slices, concatenated in order, are those 100 bytes

#### Scenario: A slow handler holds one buffer
- **WHEN** a peer sends continuously and the handler has not yet returned from a `Data` event
- **THEN** the event loop reads no further bytes from that link until the handler returns

### Requirement: Sending is all or nothing
`send(link, bytes)` SHALL either take every byte and return `Sent`, after which the caller may reuse its memory, or take none and return one of `Full`, `TooLarge`, `NotOpen` or `Closed`. `Sent` means the event loop has taken the bytes, not that the peer has received them. Bytes taken SHALL be transmitted in the order the sends were accepted. A send of zero bytes on an open link SHALL return `Sent`.

#### Scenario: The caller reuses its memory at once
- **WHEN** a library sends from a buffer, receives `Sent`, and overwrites that buffer before its handler returns
- **THEN** the peer receives the bytes as they were when `send` was called

#### Scenario: A small send is accepted
- **WHEN** a library sends 64 bytes on an open, idle link
- **THEN** `send` returns `Sent` and the peer receives those 64 bytes

#### Scenario: A send before the link opens
- **WHEN** a library sends on a dialled link before its `Opened` event
- **THEN** `send` returns `NotOpen` and nothing is queued

#### Scenario: A send after close
- **WHEN** a library calls `close` and then `send` on the same link
- **THEN** `send` returns `Closed` and nothing is queued

### Requirement: Two parts can be sent as one
An event loop that supplies the sizing group SHALL provide `send2(link, first, second)`, which behaves as one `send` of the two byte ranges joined in that order: both are taken and `Sent` is returned, or neither is taken. Its size for `Full`, `TooLarge` and `send_room` SHALL be the sum of the two lengths.

#### Scenario: A header and a body
- **WHEN** a library calls `send2` with a 20-byte header and a 100-byte body on an open, idle link
- **THEN** `send2` returns `Sent` and the peer receives the 120 bytes in order with nothing between them

#### Scenario: Neither part is taken when both do not fit
- **WHEN** `send_room` is smaller than the two parts together but larger than the first
- **THEN** `send2` returns `Full`, the peer receives none of the first part, and one `Writable` follows once room has opened

### Requirement: Send backpressure is explicit and bounded
An event loop SHALL bound the bytes it holds unsent for each link. `max_send` SHALL report the largest single send it can accept: at least 4096 bytes, one value for the whole loop. A larger send SHALL return `TooLarge`, and one that does not fit now `Full`. The sizing group's `send_room(link)` SHALL return the bytes a send would accept now, at most `max_send`, and 0 for a link that cannot send.

#### Scenario: An oversized send never fits
- **WHEN** a library sends more than `max_send` bytes in one call
- **THEN** `send` returns `TooLarge` and no `Writable` is delivered for it

#### Scenario: A reader that never reads does not grow memory
- **WHEN** a library keeps offering bytes to a peer that reads nothing, sending only when `send` accepts
- **THEN** the event loop's memory for that link stays within its per-link bound

#### Scenario: No room on a link that cannot send
- **WHEN** a library on an event loop with the sizing group asks for `send_room` of a link before its `Opened`, after `close`, after `shutdown_write`, or with a stale handle
- **THEN** it obtains 0

### Requirement: Writable follows Full once
After one or more sends on a link have returned `Full`, the event loop SHALL deliver exactly one `Writable` for that link, once each send refused since the link's previous `Writable` would fit on its own (each one, not all of them together). Further refusals before that `Writable` SHALL NOT add `Writable` events; a `Full` after it SHALL lead to another. A link that was never refused with `Full` SHALL receive no `Writable`.

#### Scenario: A full queue is reported and later reopened
- **WHEN** a peer stops reading and a library keeps sending until `send` returns `Full`, and the peer then resumes reading
- **THEN** exactly one `Writable` is delivered for that link, and a following send no larger than `send_room` returns `Sent`

#### Scenario: Several refusals share one Writable
- **WHEN** a library calls `send` three times on a full link and each call returns `Full`
- **THEN** one `Writable` is delivered for the link, not three

#### Scenario: Writable means the refused send fits
- **WHEN** sends of 2000, 1500 and 300 bytes are refused in that order and the peer then reads 1000 bytes at a time
- **THEN** `Writable` is delivered only once `send_room` is at least 2000, and sending the 2000 bytes again returns `Sent`

#### Scenario: A later refusal gets its own Writable
- **WHEN** a library receives `Writable`, sends until `send` returns `Full` again, and the peer reads again
- **THEN** a second `Writable` is delivered

### Requirement: Reading can be paused
`pause_reading(link, true)` SHALL stop `Data` events for the link, except for one that was already received before the call, until `pause_reading(link, false)`. While reading is paused the event loop SHALL NOT read from the link, so the peer experiences backpressure.

#### Scenario: Pause and resume
- **WHEN** a library pauses reading on a link, the peer sends bytes, and the library later resumes reading
- **THEN** no `Data` for bytes received after the pause is delivered while paused, and the bytes are delivered after the resume

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

### Requirement: Close does not lose accepted bytes
After `close`, an event loop SHALL hand every byte it has accepted to the transport before it ends the connection. Bytes received from the peer and not yet delivered SHALL NOT cause it to discard accepted bytes. An event loop MAY abandon accepted bytes after a limit of its own when the peer does not take them. `close` does not promise that the peer's application receives or processes the bytes.

#### Scenario: Close with unread input
- **WHEN** a peer has sent bytes the library has not been given yet, and the library sends a reply and calls `close`
- **THEN** the peer still receives the whole reply followed by end of stream, and the library receives no `Data` for the unread bytes

#### Scenario: A peer that never reads
- **WHEN** a library sends, calls `close`, and the peer never reads
- **THEN** the library receives its one `Closed` with reason `Local` no later than the event loop's limit, and the event loop holds nothing for the link after that

### Requirement: Peer end of stream and half-close
When the peer finishes sending, an event loop SHALL send the bytes already accepted and close the link with `PeerClosed`. The half-close group adds `set_keep_open_on_eof(link, keep)`, `shutdown_write(link)` and `PeerEof`: with keep set the loop SHALL deliver `PeerEof` once, after every `Data`, and keep the link open; `shutdown_write` SHALL end local sending once accepted bytes are out (later sends return `Closed`), and the link SHALL close when the peer has finished too.

#### Scenario: Default behaviour on peer end of stream
- **WHEN** a peer sends a request and shuts down its sending side, and the library has not opted in to keep the link open
- **THEN** bytes the library already sent reach the peer and the handler receives `Closed` with reason `PeerClosed`

#### Scenario: Answering after the peer half-closes
- **WHEN** a library on an event loop with the half-close group has opted in, the peer half-closes, and the library then sends a reply and calls `shutdown_write`
- **THEN** the handler receives `PeerEof` once after all `Data`, the peer receives the whole reply followed by end of stream, and `Closed` follows

### Requirement: Close reasons are portable
A `Closed` event SHALL carry one of the portable reasons `PeerClosed`, `PeerReset`, `ConnectFailed`, `IdleTimeout`, `HalfCloseTimeout`, `Local`, `Shutdown` or `Error`, or a loop-specific reason carrying a numeric code. An event loop MAY close a link on its own policy at any time. A portable library SHALL handle every reason and SHALL treat a loop-specific reason as it treats `Error`.

#### Scenario: The peer resets the connection
- **WHEN** a peer aborts an open link
- **THEN** the handler receives `Closed` with reason `PeerReset`

#### Scenario: A loop-specific reason reaches a portable library
- **WHEN** an event loop closes a link for a reason outside the portable set
- **THEN** the `Closed` event carries the loop-specific reason and its code, and the example client library handles it as it handles `Error`

### Requirement: Time and ticks
An event loop SHALL expose `now_ms`, a monotonic millisecond clock that never goes backwards, and SHALL deliver a `Tick` carrying that clock at least every 100 ms while the loop runs. `tick_by(at_ms)` SHALL cause a `Tick` at or after `at_ms` to be delivered promptly once the clock reaches `at_ms`. An event loop need keep only the earliest outstanding request, which the first such `Tick` satisfies.

#### Scenario: Regular ticks
- **WHEN** a loop runs for one second of its clock with no link activity
- **THEN** at least ten `Tick` events are delivered and their times never decrease

#### Scenario: A deadline shorter than the tick period
- **WHEN** a library calls `tick_by(now_ms + 20)`
- **THEN** a `Tick` whose time is at or after the requested time is delivered before the next regular 100 ms tick would have been

#### Scenario: Two libraries with different deadlines
- **WHEN** one library requests a tick in 20 ms and another in 50 ms, and each re-requests its own deadline while handling every `Tick`
- **THEN** each library observes a `Tick` at or after its own deadline before the next regular tick after it

### Requirement: End-of-pass notification
An event loop MAY supply the batching group. One that does SHALL deliver exactly one `PassEnd`, last, in every pass that delivered a link event, and none in a pass of only ticks or nothing: no link event or `Tick` of that pass SHALL follow it, and calls made while handling it SHALL NOT cause a second one. A library SHALL NOT depend on `PassEnd` for correctness: it is for batching only.

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
