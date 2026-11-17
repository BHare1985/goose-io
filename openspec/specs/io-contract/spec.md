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
Contract types and operations SHALL NOT expose file descriptors, socket address structures, poll masks, or any other operating-system or backend object. Addresses SHALL be text: numeric `ip:port` for IPv4 and `[ip]:port` for IPv6, and, for an event loop that supplies the unix group, `unix:/path` or `unix:///path`. An IPv6 zone identifier is not part of an address: text that contains one SHALL be treated as malformed.

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
- **WHEN** a link is closed, its slot is reused by a new link, and a library then calls `send`, `close` or `pause_reading` with the old handle
- **THEN** the new link is unaffected, no bytes are sent on it, and `send` returns `Closed`

#### Scenario: The handle is still valid while Closed is handled
- **WHEN** a handler receives `Closed` for a link and calls `peer_address` with that link before returning
- **THEN** it obtains the link's peer address, and the same call made after the handler has returned obtains an empty value

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

### Requirement: Listening
`listen(address)` SHALL start accepting TCP connections and return a listener handle, or an error naming its kind and a loop-specific code. Each accepted connection SHALL produce `Opened` carrying the listener's handle. `listener_port(listener)` SHALL return the bound port, including one the system chose for port zero. An event loop that supplies the inspection group SHALL provide `stop_listening(listener)`, which stops new connections without closing accepted links.

#### Scenario: A connection is accepted
- **WHEN** a library listens on a free port and a peer connects
- **THEN** the handler receives `Opened` with that listener's handle

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
An event loop that supplies the inspection group SHALL provide `peer_address(link)`, which returns the remote endpoint of an open, write-shut or closing link as numeric text in the form `dial` accepts, and an empty value for a dialling link, for a link whose `Closed` has been delivered, and for a stale or invalid handle. IPv6 text SHALL be lower case with the longest run of two or more zero groups written as `::`. The value SHALL be available from the link's `Opened` event until its `Closed` event has been delivered.

#### Scenario: An accepted link names its peer
- **WHEN** a library dials a listener on the same loop and the listening side asks for the peer address of the accepted link
- **THEN** it obtains numeric text whose address part is the dialling side's address

#### Scenario: A dialled link names its target
- **WHEN** a library dials `127.0.0.1` on a listener's port and asks for the peer address after `Opened`
- **THEN** it obtains that address and port as text

#### Scenario: A closed link has no peer address
- **WHEN** a library asks for the peer address of a link after its `Closed` event
- **THEN** it obtains an empty value

#### Scenario: A dialling link has no peer address
- **WHEN** a library asks for the peer address of a link `dial` has just returned
- **THEN** it obtains an empty value

#### Scenario: A closing link still names its peer
- **WHEN** a library calls `close` on an open link and asks for its peer address before the link's `Closed` is delivered
- **THEN** it obtains the same address it obtained while the link was open

### Requirement: Dialling never blocks and always ends in one event
`dial(address, connect_ms)` SHALL start an outbound TCP connection and return a valid link at once. An event loop SHALL NOT resolve host names. The outcome SHALL be `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed, the connection is refused or unreachable, the event loop is out of resources, or `connect_ms` elapses. A `connect_ms` of zero SHALL mean the event loop's default. Every event of the link SHALL be delivered after the handler that called `dial` has returned.

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

#### Scenario: No event inside the dial
- **WHEN** a library stores the link `dial` returned in its own state and the dial fails at once
- **THEN** the library's handler has returned from the call that dialled before the `Closed` is delivered

### Requirement: A failed dial says why
A `ConnectFailed` reason SHALL carry a kind: `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress` or `Other`. An event loop SHALL report `BadAddress` for text that is not an address of a form it accepts (a numeric address, and `unix:/path` or `unix:///path` where it supplies the unix group), `TimedOut` when `connect_ms` elapses, and `NoResources` when it has no link left. For every other failure it SHALL translate what its system reports, and report `Other` when it cannot tell. No system error number is part of the reason.

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

### Requirement: The core is twelve operations and five events
The core operations SHALL be `listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `now_ms`, `tick_by`, `serve`, `stop` and `draining`. The core events SHALL be `Opened`, `Data`, `Writable`, `Closed` and `Tick`. `listener_port` and `pause_reading` are in the core because a suite that runs both ends of every link on one loop cannot otherwise reach a system-chosen port or make a peer that does not read.

#### Scenario: The core is enough for a client
- **WHEN** the example line client is built against an event loop that supplies only the core
- **THEN** the build succeeds and the client's tests pass

### Requirement: Each group is named and checked on its own
The groups SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`), batching (`PassEnd`) and unix (the address form `unix:/path`). The contract package SHALL offer a compile-time check for the core and for each group that has operations, each naming every operation of its part. Batching has only an event, and unix has only an address form, and so neither has a check.

#### Scenario: The core check
- **WHEN** an event loop's root program calls the core check
- **THEN** it compiles if the loop supplies every operation of the core with the contract's types, and otherwise the error names the first operation that is missing

#### Scenario: A group check
- **WHEN** an event loop that supplies the abort group calls the abort check
- **THEN** it compiles, and an event loop without `reset` calling it gets an error naming `reset`

#### Scenario: An operation that was removed
- **WHEN** a library calls `set_user` or `user`, or passes a tag to `listen` or `dial`
- **THEN** the build fails and the error names the call

### Requirement: Three roles: event loop, library, application
The contract SHALL define an event loop (owns the thread and the sockets, delivers events, performs operations), a library (handles events, calls operations) and an application (the program that runs the event loop and passes events to its libraries). A library SHALL depend only on the contract, never on the types of one event loop. No role SHALL be required to store a callback, allocate from a heap, or call through a function pointer.

#### Scenario: A library runs on two event loops unchanged
- **WHEN** the same library source is built with two different conforming event loops that supply what the library uses
- **THEN** both builds succeed with no change to the library source and no adapter code between the library and either loop

#### Scenario: A library imports no event loop
- **WHEN** the example libraries' sources are inspected
- **THEN** they import the contract and nothing that names a specific event loop

### Requirement: What the contract covers
The contract SHALL cover TCP byte streams over IPv4 and IPv6, stream sockets at a path in the unix group, ticks and deadlines, and running and stopping one loop, and nothing else. Name resolution, TLS, UDP, files, signals, cross-thread messaging, starting several loops, and joining two links for forwarding SHALL NOT be required of an event loop. Nothing in a group SHALL be required of an event loop that does not supply the group.

#### Scenario: IPv6 is covered
- **WHEN** a library listens on `[::1]` and dials that address
- **THEN** the link opens and carries data as an IPv4 link does

#### Scenario: An event loop without extras conforms to the core
- **WHEN** an event loop implements only the operations and events of the core
- **THEN** it passes the core of the conformance suite

### Requirement: The unix group is the address form unix:/path
An event loop that supplies the unix group SHALL accept `unix:/path` in `listen` and `dial`, naming a connection-oriented stream socket, with the same operations, events, results and rules as for a TCP address. The group SHALL add no operation, event or type. An event loop that does not supply it SHALL treat the text as any address it does not accept: `listen` returns an error of kind `BadAddress`, and `dial` ends with one `Closed` of reason `ConnectFailed` with kind `BadAddress`.

#### Scenario: A listener and a dial on a path
- **WHEN** a library on an event loop that supplies the unix group calls `listen("unix:/run/x.sock", tag)` and the same loop calls `dial("unix:/run/x.sock", tag2, 0)`
- **THEN** the listen succeeds, both links receive `Opened` (the accepted one with the listener's tag and handle, the dialled one with no listener), and bytes sent on one arrive on the other in order

#### Scenario: A failure the system reports uses an existing kind
- **WHEN** a library dials a well-formed path that the system refuses (nothing listens, or access is denied)
- **THEN** the `Closed` event's reason is `ConnectFailed` with the kind the contract already has for that failure (`Refused` or `Denied`, or `Other` when the event loop cannot tell), and no kind specific to Unix sockets exists

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

### Requirement: unix:///path is a spelling of unix:/path
An event loop that supplies the unix group SHALL also accept the URL spelling `unix:///path`, and it SHALL name the same path as `unix:/path`, so the two spellings are one endpoint. The path follows `unix://` and SHALL begin with a single `/`: an authority (`unix://host/x`, `unix://x`) and a doubled slash (`unix:////x`) are malformed. The spelling SHALL NOT be decoded or split: `%`, `?` and `#` are bytes of the path. The limit of 103 bytes is on the path.

#### Scenario: The URL spelling names the same path
- **WHEN** a library on an event loop that supplies the unix group calls `listen("unix:/run/x.sock", tag)` and the same loop calls `dial("unix:///run/x.sock", tag2, 0)`
- **THEN** both links receive `Opened`, and a `listen` on `unix:///run/x.sock` returns an error of kind `AddressInUse`

#### Scenario: An authority or a doubled slash
- **WHEN** a library on an event loop that supplies the unix group dials `unix://host/x.sock`, `unix://x.sock`, `unix:////x.sock` and `unix://`
- **THEN** each dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress`

#### Scenario: Nothing is decoded
- **WHEN** a library listens on `unix:///run/a%20b.sock` and dials `unix:/run/a%20b.sock`
- **THEN** the dial opens, and a dial to `unix:/run/a b.sock` ends with `ConnectFailed` of kind `Refused`

#### Scenario: A held path is held under either spelling
- **WHEN** a library listens on `unix:/run/a.sock`, then on `unix:///run/a.sock`
- **THEN** the second `listen` returns an error of kind `AddressInUse`

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

### Requirement: Slot numbers are dense
An event loop SHALL give a new link a slot freed earlier before it gives a slot it has never used, so that no link's slot is ever as large as the greatest number of links valid at once on that loop, plus the slots the event loop has retired. A slot whose generations are used up MAY be retired and not given again. A library MAY therefore size a table by slot to the event loop's peak, and SHALL NOT assume the bound is its own peak of links.

#### Scenario: Slots are reused before new ones are issued
- **WHEN** a library opens eight links, closes all of them, waits for every `Closed`, and opens eight more
- **THEN** every link of the second eight has a slot below eight

#### Scenario: A reused slot has a new generation
- **WHEN** a slot is reused by a new link
- **THEN** the new link's generation differs from the generation of the link that held it before

#### Scenario: The bound is the loop's peak
- **WHEN** a library keeps two links while other libraries on the same event loop hold 99,999 others, and the library then opens another link
- **THEN** that link's slot may be as high as 99,999, and no link's slot reaches 100,001, not counting retired slots

### Requirement: A slot is freed when its Closed has been handled
A slot SHALL be free for a new link only after every handler of its link's `Closed` event has returned, and not when the event loop queues or generates the event, so that an old link keeps its identity while a library handles its `Closed`.

#### Scenario: A slot is not reused while Closed is handled
- **WHEN** a handler receives `Closed` for a link and opens a new link before it returns
- **THEN** the new link's slot is not the slot of the link being closed

### Requirement: A link map finds state by link
The contract package SHALL offer `LinkMap<T>`, a table of a library's own values keyed by link. `put` SHALL store a value for a valid link, replacing whatever an earlier link of the same slot left. `find` SHALL return a reference to the value for a link that was put and not dropped, and nothing for a link that is invalid, stale, never put, or dropped. `drop` SHALL empty the entry for that link and no other.

#### Scenario: A stale link finds nothing
- **WHEN** a value is put for a link, the link's slot is reused by a new link, and `find` is called with the old link
- **THEN** it returns nothing, and `find` with the new link returns nothing until a value is put for it

#### Scenario: A foreign link finds nothing
- **WHEN** a map holds values for some links and `find` is called with a link it was never given
- **THEN** it returns nothing, whatever the link's slot

#### Scenario: Dropping touches one entry
- **WHEN** values are put for two links and one is dropped
- **THEN** `find` returns nothing for it and still returns the other's value

#### Scenario: A put over a stale entry replaces it
- **WHEN** a value is put for a link, the link's slot is reused by a new link without a `drop`, and a value is put for the new link
- **THEN** `find` with the new link returns the new value and `find` with the old link returns nothing

### Requirement: A reference from a link map stays valid
A reference `find` returned SHALL stay valid across later calls to `put`, and a reference kept past `drop` SHALL read an empty value and is not an entry for any later link.

#### Scenario: Growing does not move values
- **WHEN** a library holds a reference from `find` and puts values for links with higher slots
- **THEN** the reference still reads and writes the same value

#### Scenario: A dropped value is gone
- **WHEN** a value is put for a link, a reference to it is kept, and the link is dropped
- **THEN** the reference reads an empty value and `find` returns nothing for the link

### Requirement: A link map is one loop's helper with a stated cost
A map SHALL be used only with links of the one event loop that created them. `LinkMap` is a helper and not a requirement: a library MAY keep its state any other way. The flat `LinkMap` has memory equal to the event loop's peak slot count times the size of the library's state, and the contract documents that cost.

#### Scenario: One map for each loop
- **WHEN** a library is given links by two event loops
- **THEN** it keeps one map for each loop, and neither map is asked about the other loop's links

### Requirement: A link event is recognised by what the library holds
Every link event SHALL carry its link, and `Opened` the listener that accepted it (none for a dialled link). A library SHALL recognise its own links by what it holds: a dialled link is the one `dial` returned to it, an accepted link is one whose `Opened` names a listener it started, and a later event is one whose link it has state for. `Tick` and `PassEnd` go to every library. An event SHALL carry no value attached by the application or a library.

#### Scenario: An accepted link names its listener
- **WHEN** a library listens twice, a peer connects to the second listener, and the handler receives `Opened`
- **THEN** the event carries the second listener's handle and not the first's

#### Scenario: A dial that fails at once is found by its link
- **WHEN** a library dials a malformed address, keeps the link `dial` returned, and the failure is then delivered
- **THEN** the `Closed` event carries that same link, and the library finds its own state for it

#### Scenario: A dialled link's Opened does not replace its state
- **WHEN** a library stores state for a link `dial` returned, and the link's `Opened` is then delivered
- **THEN** the library finds the state it stored, unchanged, and handles the event

### Requirement: A library claims only the events of links it owns
A library SHALL treat any link event for a link it does not own as not handled, and SHALL report an event as handled only for a link it owns: for `Data`, `Writable`, `PeerEof` and `Closed` a library that has no state for the link reports it as not handled and runs none of its handling, so that the application can offer the event to the next library.

#### Scenario: Two libraries share one loop
- **WHEN** a server library and a client library run on the same loop and a `Data` event arrives for a link that the client library dialled
- **THEN** the server library has no state for that link and reports the event as not handled, and the client library handles it

#### Scenario: Another library's Closed is not handled
- **WHEN** a server library and a client library run on the same loop and a `Closed` arrives for a link that the client library dialled
- **THEN** the server library reports it as not handled and runs none of its close handling, and the client library handles it and drops its state

#### Scenario: Two instances of one library on one loop
- **WHEN** two instances of the same library each listen on their own address on one loop, and a peer connects to the second
- **THEN** only the second instance handles that link's `Opened` and every later event, and the first reports each of them as not handled

### Requirement: A link is in one of five states
A library SHALL be able to tell the state of each of its links from the calls it made and the events it received: dialling (after `dial`, before any event), open (after `Opened`), write-shut (after `shutdown_write` on an open link), closing (after `close` or `reset`, before `Closed`) and ended (after `Closed`, or never issued). An event loop MAY have begun to end a link that its library still sees as open.

#### Scenario: A dialled link moves through the states
- **WHEN** a library dials a listening address, receives `Opened`, calls `close`, and receives `Closed`
- **THEN** the link was dialling until `Opened`, open until `close`, closing until `Closed`, and ended after it

#### Scenario: The event loop ends a link the library sees as open
- **WHEN** the peer of an open link closes its end and the library sends on the link before its `Closed` is delivered
- **THEN** `send` returns `Sent` or `Closed`, and the link's `Closed` event follows whichever it returned

### Requirement: Sending has one result in each link state
`send` and `send2` SHALL return `NotOpen` on a dialling link; `Sent`, `Full` or `TooLarge` on an open link, or `Closed` when the event loop has begun to end it; and `Closed` on a write-shut, closing or ended link. `send_room` SHALL be 0 in every state but open.

#### Scenario: One link in each state
- **WHEN** a library sends 10 bytes on one link while it is dialling, while it is open, after calling `close`, and after its `Closed`
- **THEN** `send` returns `NotOpen`, `Sent`, `Closed` and `Closed` in turn

#### Scenario: Sending on a write-shut link
- **WHEN** a library on an event loop with the half-close group calls `shutdown_write` on an open link and then sends on it
- **THEN** `send` returns `Closed`, and with the sizing group `send2` returns `Closed` and `send_room` returns 0

### Requirement: A Closed send result is final
Once `send` or `send2` has returned `Closed` for a link, sending on it SHALL stay ended: every later `send` and `send2` SHALL return `Closed`, `send_room` SHALL return 0, and no `Writable` SHALL be delivered for it. When the library had called none of `shutdown_write`, `close` and `reset` on the link, the result SHALL also mean that the event loop is ending the link, and its `Closed` event SHALL follow with no further call.

#### Scenario: The peer goes away
- **WHEN** a library's `send` returns `Closed` on a link it has neither closed nor shut, after the link's peer closed its end
- **THEN** every later `send` on the link returns `Closed`, no `Writable` is delivered for it, and its `Closed` event follows

#### Scenario: A refused send then a Closed result
- **WHEN** a library is refused with `Full`, and a later send on the same link returns `Closed`
- **THEN** no `Writable` is delivered for the link, and its `Closed` event follows

#### Scenario: After shutdown a Closed result concerns only sending
- **WHEN** a library on an event loop with the half-close group calls `shutdown_write` on an open link, a send on it returns `Closed`, and the peer then sends bytes and later finishes
- **THEN** the library receives those bytes as `Data`, no `Writable`, and the link's `Closed` only after the peer has finished

### Requirement: Ending a link has one result in each link state
`close` and `reset` on a dialling link SHALL abandon the attempt and lead to one `Closed` with reason `Local` and no `Opened`. On an open or write-shut link they SHALL end it as *Closing* states. On a closing or ended link they SHALL have no effect and SHALL NOT cause a second `Closed`. `shutdown_write` SHALL have an effect only on an open link.

#### Scenario: Close twice
- **WHEN** a library calls `close` on an open link and calls `close` on it again before its `Closed` is delivered
- **THEN** the link receives exactly one `Closed`, with reason `Local`

#### Scenario: Reset a dial in progress
- **WHEN** a library on an event loop with the abort group calls `reset` on a dialling link
- **THEN** no `Opened` is delivered for it and it receives one `Closed` with reason `Local`

#### Scenario: Shutdown before the link opens
- **WHEN** a library on an event loop with the half-close group calls `shutdown_write` on a dialling link and the link then opens
- **THEN** a send after `Opened` returns `Sent`: the call had no effect

#### Scenario: Close after shutdown
- **WHEN** a library on an event loop with the half-close group calls `shutdown_write` on an open link and then `close`
- **THEN** the link receives no further `Data` or `PeerEof` and exactly one `Closed`, with reason `Local`

#### Scenario: Reset after close
- **WHEN** a library on an event loop with the abort group calls `close` and then `reset` on the same link before its `Closed`
- **THEN** the link receives exactly one `Closed`, with reason `Local`

### Requirement: Pausing takes effect in every live state
`pause_reading` SHALL take effect on a dialling, open or write-shut link, so a link paused before its `Opened` delivers no `Data` until it is resumed. It SHALL have no effect on a closing or ended link.

#### Scenario: Pause before Opened
- **WHEN** a library dials, calls `pause_reading(link, true)` before `Opened`, and the peer sends bytes as soon as the link opens
- **THEN** the library receives `Opened` and no `Data` until it calls `pause_reading(link, false)`, after which the bytes are delivered in order

### Requirement: Keep-open is configured no later than Opened
`set_keep_open_on_eof` SHALL be recorded when called on a dialling link or while handling the link's `Opened`, and the setting SHALL apply from the moment that handler returns. A call made later SHALL have no effect, whether or not the peer has finished. An event loop that observed the peer's end of stream before then SHALL act on it only after the `Opened` handler has returned, as the setting says.

#### Scenario: Keep open set while dialling
- **WHEN** a library on an event loop with the half-close group calls `set_keep_open_on_eof(link, true)` on a dialling link, and the peer sends bytes and finishes as soon as the link opens
- **THEN** the library receives `Opened`, the `Data`, and one `PeerEof`, and the link stays open for sending

#### Scenario: Keep open set while handling Opened
- **WHEN** a library on an event loop with the half-close group calls `set_keep_open_on_eof(link, true)` while handling the `Opened` of an accepted link, and the peer sends bytes and finishes
- **THEN** the library receives the `Data` and one `PeerEof`, and the link stays open for sending

#### Scenario: A late call has no effect
- **WHEN** a library on an event loop with the half-close group calls `set_keep_open_on_eof(link, true)` while handling the link's first `Data`, after its `Opened` handler has returned, and the peer then finishes
- **THEN** no `PeerEof` is delivered and the link receives `Closed` with reason `PeerClosed`

#### Scenario: An end of stream that arrives before Opened is handled
- **WHEN** the peer of a dialled link sends bytes and finishes before the library's `Opened` handler for the link has run, and the library calls `set_keep_open_on_eof(link, true)` in that handler
- **THEN** the library receives the `Data` and one `PeerEof`, and the link stays open for sending

### Requirement: Each operation says how it completes
Every operation SHALL take its effect and give its result when it returns. Only these SHALL have a later notification: `dial` (one `Opened` or `Closed`), `close` and `reset` (one `Closed`), a send refused with `Full` (one `Writable` or `Closed`), `tick_by` (a `Tick` at or after the earliest outstanding request, which may answer several calls), and `stop` (`serve` returning). No other event SHALL report an operation's result.

#### Scenario: Shutdown is complete when it returns
- **WHEN** a library on an event loop with the half-close group calls `shutdown_write` on an open link and sends on it in the same handler
- **THEN** that send returns `Closed`, and no event is delivered for the link because of the call other than its eventual `Closed`

#### Scenario: Pausing is complete when it returns
- **WHEN** a library calls `pause_reading(link, true)` while handling a `Data` event, and the peer goes on sending
- **THEN** no further `Data` is delivered for the link until it is resumed, and no event reports the pause

#### Scenario: One Tick may answer several requests
- **WHEN** a library calls `tick_by(now_ms + 20)` and `tick_by(now_ms + 50)` in one handler
- **THEN** a `Tick` at or after the earlier time is delivered before the next regular `Tick`, and that one `Tick` may be the only notification for both calls

### Requirement: The invalid link is reserved
The default `Link`, slot 0 and generation 0, SHALL be the one invalid link value of every event loop. No event loop SHALL issue a link with generation 0, and every operation SHALL treat a link of generation 0 as a handle that was never issued.

#### Scenario: No issued link has generation 0
- **WHEN** a loop issues links through `dial` and through accepted connections, reusing slots
- **THEN** every link it issues has a non-zero generation, and `is_valid` is true for each

#### Scenario: The invalid link is never issued
- **WHEN** a library calls `send`, `close` and `pause_reading` with the default `Link`
- **THEN** `send` returns `Closed` and no link of the loop is affected

### Requirement: A slot and generation pair is never issued twice
An event loop SHALL NOT issue a slot and generation pair it has already issued on the same loop. A slot whose generations are used up SHALL be retired, not wrapped. When no slot can be issued, `dial` SHALL fail with `ConnectFailed` of kind `NoResources`.

#### Scenario: Handles in a long run are distinct
- **WHEN** a loop opens and closes several hundred links one after another, so that slots are reused
- **THEN** no two of the links it issued have the same slot and generation

### Requirement: A slot is held until its Closed is delivered
An event loop SHALL NOT issue a link in a slot until the link that held the slot before has had its `Closed` delivered, even with a new generation. A slot therefore names at most one link that has not ended.

#### Scenario: A slot is not reused while its Closed is pending
- **WHEN** a library calls `close` on an open link and dials a new link in the same handler
- **THEN** the new link's slot is not the closed link's slot

### Requirement: A loop is set up, serving, draining or finished
A loop SHALL be set up until `serve` is called, serving until `stop`, draining from `stop` until `serve` returns, and finished afterwards. While set up, operations SHALL work as they do while serving, and the events they cause SHALL be delivered once `serve` runs.

#### Scenario: Listening and dialling before serve
- **WHEN** an application listens on an address and dials it before calling `serve`
- **THEN** no event is delivered before `serve` is called, and `serve` delivers `Opened` for both links

### Requirement: A finished loop does nothing
On a finished loop every operation SHALL return without blocking or delivering an event. `dial` SHALL return the invalid link, issuing no link and starting no connection; this is the one exception to *Dialling never blocks and always ends in one event*. `send` and `send2` SHALL return `Closed`, `send_room` 0, and `listen` SHALL fail with kind `Other`. Every other operation SHALL have no effect, and a second `serve` SHALL return at once.

#### Scenario: Operations after serve returns
- **WHEN** `serve` has returned and the application calls `send` on a link it held, `listen`, `dial`, `close`, `pause_reading`, `tick_by`, `draining` and `now_ms`
- **THEN** `send` returns `Closed`, `listen` returns an error of kind `Other`, `dial` returns a link for which `is_valid` is false, `draining` is true, `now_ms` is no earlier than before, and no call blocks

#### Scenario: Serve a second time
- **WHEN** an application calls `serve` on a finished loop
- **THEN** `serve` returns at once and its handler is never called

### Requirement: A loop belongs to the thread that serves it
An application SHALL make every call to a loop on the thread that calls `serve`, the calls before `serve` included, and SHALL NOT use one loop from two threads. An event loop MAY bind itself to the thread of the first call made to it. No operation of the contract crosses threads.

#### Scenario: Setting up on the serving thread
- **WHEN** the example programs and the conformance suite's entry points are inspected
- **THEN** each one constructs its loop, sets it up and calls `serve` on one thread

### Requirement: The end of the grace period
When the grace period ends, an event loop MAY discard the bytes accepted on a remaining link, including bytes already handed to the transport, and MAY end the connection gracefully or by abort; a library SHALL NOT assume that those bytes reach the peer. A link on which the library called `close` or `reset` before the grace period ended, before or after `stop`, SHALL end with reason `Local`, never `Shutdown`.

#### Scenario: Close, then stop
- **WHEN** a library sends to a peer that has paused reading, calls `close`, and then calls `stop` with a grace period that ends before the peer resumes
- **THEN** the library's link receives one `Closed` with reason `Local`

#### Scenario: Stop, then close during the grace period
- **WHEN** a library calls `stop` with a grace period, then sends to a peer that has paused reading and calls `close` before the grace period ends, and the peer does not resume before it ends
- **THEN** the library's link receives one `Closed` with reason `Local`
