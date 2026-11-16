# Spec Delta

## Purpose

Defines the provider-neutral contract between an event loop (a provider) and the libraries that run on it, so an async client or server library written once runs on any conforming provider, whether that provider is built on readiness (epoll, kqueue) or completion (io_uring, IOCP).

## ADDED Requirements

### Requirement: One contract with two roles
The contract SHALL define a provider role (delivers events, performs the operations) and a library role (handles events, calls the operations). A library SHALL depend only on the contract's types and operations, never on a provider's own types. The contract SHALL NOT require either role to store a callback, allocate from a heap, or call through a function pointer.

#### Scenario: A library compiles against two providers unchanged
- **WHEN** the same library source is built once with the reference epoll provider and once with the fake provider
- **THEN** both builds succeed with no change to the library source and no adapter code between the library and either provider

#### Scenario: A library imports no provider
- **WHEN** the example client library's sources are inspected
- **THEN** they import the contract and nothing that names a specific provider

### Requirement: Links are generation-checked and worker-affine
A link SHALL be a fixed-size handle made of a slot and a generation, valid from the call or event that created it until its `Closed` event has been delivered. Every operation on a link whose generation no longer matches SHALL have no effect on any other link and SHALL report the link as closed where the operation returns a status. A link SHALL be used only on the worker that created it.

#### Scenario: A stale handle cannot reach a reused slot
- **WHEN** a link is closed, its slot is reused by a new link, and a library then calls `send`, `close`, `set_user` or `pause_reading` with the old handle
- **THEN** the new link is unaffected, no bytes are sent on it, and `send` returns `Closed`

#### Scenario: An unset handle is recognisably invalid
- **WHEN** a library holds a default-constructed link and asks whether it is valid
- **THEN** the answer is no, and every operation on it has no effect

### Requirement: Events are delivered to one handler, one at a time
A provider SHALL deliver every event of a worker to a single handler supplied by the application, on that worker's thread, one event at a time. A provider SHALL NOT deliver an event from inside a contract operation: an event caused by an operation called during a handler SHALL be delivered after that handler returns.

#### Scenario: A send that closes the link does not re-enter the handler
- **WHEN** a handler calls `send` on a link whose peer has reset the connection
- **THEN** `send` returns before any `Closed` event is delivered, and the `Closed` event arrives as a later, separate delivery

### Requirement: Link events follow a fixed order
For each link a provider SHALL deliver at most one `Opened`, before any other event of that link; `Data` events in the order the bytes arrived; at most one `PeerEof`, after every `Data`; and exactly one `Closed`, after which no event for that link is delivered.

#### Scenario: An accepted link
- **WHEN** a peer connects, sends two messages and disconnects
- **THEN** the handler sees `Opened`, then `Data` events carrying the bytes in order, then `Closed`, and nothing further for that link

#### Scenario: A link that never opens
- **WHEN** a dial fails for any reason
- **THEN** the handler sees exactly one `Closed` for that link and never an `Opened`

### Requirement: Every link event names its owner
Every link event SHALL carry the link, the 16-bit tag given when the link was dialled or its listener was created, and the 32-bit user value last set for the link (zero until set). The application assigns tags to libraries; a library SHALL treat an event whose tag is not its own as not handled.

#### Scenario: Two libraries share one worker
- **WHEN** a server library with tag 1 and a client library with tag 2 run on the same worker and a `Data` event arrives for a link dialled with tag 2
- **THEN** the event carries tag 2, the server library reports it as not handled, and the client library handles it

#### Scenario: The user value comes back
- **WHEN** a library calls `set_user(link, 41)` and bytes later arrive on that link
- **THEN** the `Data` event carries user value 41

### Requirement: Listening
`listen(address, tag)` SHALL start accepting TCP connections on a numeric address and return a listener handle, or an error naming its kind and the operating system's code. Each accepted connection SHALL produce an `Opened` event carrying the listener's tag and handle. `stop_listening(listener)` SHALL stop new connections without closing links already accepted.

#### Scenario: A connection is accepted
- **WHEN** a library listens on a free port with tag 1 and a peer connects
- **THEN** the handler receives `Opened` with tag 1 and that listener's handle

#### Scenario: The address is taken
- **WHEN** a library listens on a port that another process already holds exclusively
- **THEN** `listen` returns an error of kind `AddressInUse` with the operating system's code, and no events follow

#### Scenario: Stopping a listener keeps its links
- **WHEN** a library calls `stop_listening` while a link accepted from that listener is open
- **THEN** new connection attempts are no longer accepted and the open link continues to deliver and send data

### Requirement: Dialling never blocks and always ends in one event
`dial(address, tag, connect_ms)` SHALL start an outbound TCP connection to a numeric address and return a valid link immediately. A provider SHALL NOT resolve host names. The outcome SHALL be either `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed, the connection is refused or unreachable, the provider is out of resources, or `connect_ms` elapses. A `connect_ms` of zero SHALL mean the provider's default.

#### Scenario: A successful dial
- **WHEN** a library dials a listening address
- **THEN** `dial` returns at once, and an `Opened` event for that link follows

#### Scenario: A refused dial
- **WHEN** a library dials an address nothing listens on
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows and no `Opened`

#### Scenario: A dial that times out
- **WHEN** a library dials a blackholed address with `connect_ms` of 200
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows no earlier than 200 ms after the dial

#### Scenario: A host name is rejected, not resolved
- **WHEN** a library dials `db.example.com:5432`
- **THEN** exactly one `Closed` with reason `ConnectFailed` follows and no name lookup is performed

### Requirement: Received bytes are lent for the duration of the event
A `Data` event SHALL carry a read-only slice of bytes owned by the provider and valid only until the handler returns. A provider SHALL have at most one undelivered `Data` event per link and SHALL NOT read further from that link until the handler has returned from it.

#### Scenario: Bytes arrive as a slice
- **WHEN** a peer sends 100 bytes
- **THEN** the handler receives one or more `Data` events whose slices, concatenated in order, are those 100 bytes

#### Scenario: A slow handler holds one buffer
- **WHEN** a peer sends continuously and the handler has not yet returned from a `Data` event
- **THEN** the provider reads no further bytes from that link until the handler returns

### Requirement: Sending is all or nothing
`send(link, bytes)` SHALL either take every byte and return `Sent`, after which the caller may reuse its memory, or take none and return one of `Full`, `TooLarge`, `NotOpen` or `Closed`. Bytes taken SHALL be transmitted in the order the sends were accepted. A send of zero bytes on an open link SHALL return `Sent`.

#### Scenario: A small send is accepted
- **WHEN** a library sends 64 bytes on an open, idle link
- **THEN** `send` returns `Sent` and the peer receives those 64 bytes

#### Scenario: A send before the link opens
- **WHEN** a library sends on a dialled link before its `Opened` event
- **THEN** `send` returns `NotOpen` and nothing is queued

#### Scenario: A send after close
- **WHEN** a library calls `close` and then `send` on the same link
- **THEN** `send` returns `Closed` and nothing is queued

### Requirement: Send backpressure is explicit and bounded
A provider SHALL bound the bytes it holds unsent for each link and report the largest single send it can ever accept as `max_send`, which SHALL be at least 4096 bytes. A send larger than `max_send` SHALL return `TooLarge`. A send that does not fit now SHALL return `Full`, and the provider SHALL then deliver exactly one `Writable` for that refusal once room has opened. `send_room(link)` SHALL return the number of bytes a send would accept now.

#### Scenario: A full queue is reported and later reopened
- **WHEN** a peer stops reading and a library keeps sending until `send` returns `Full`, and the peer then resumes reading
- **THEN** exactly one `Writable` is delivered for that link, and a following send no larger than `send_room` returns `Sent`

#### Scenario: An oversized send never fits
- **WHEN** a library sends more than `max_send` bytes in one call
- **THEN** `send` returns `TooLarge` and no `Writable` is delivered for it

#### Scenario: A reader that never reads does not grow memory
- **WHEN** a library keeps offering bytes to a peer that reads nothing, sending only when `send` accepts
- **THEN** the provider's memory for that link stays within its per-link bound

### Requirement: Reading can be paused
`pause_reading(link, true)` SHALL stop `Data` events for the link, except for one that was already received before the call, until `pause_reading(link, false)`. While reading is paused the provider SHALL NOT read from the link, so the peer experiences TCP backpressure.

#### Scenario: Pause and resume
- **WHEN** a library pauses reading on a link, the peer sends bytes, and the library later resumes reading
- **THEN** no `Data` for bytes received after the pause is delivered while paused, and the bytes are delivered after the resume

### Requirement: Closing
`close(link)` SHALL transmit the bytes already accepted and then close the link; on a link that has not opened it SHALL cancel the dial. `reset(link)` SHALL close at once with a TCP reset and discard unsent bytes. In both cases no further `Data` SHALL be delivered and exactly one `Closed` with reason `Local` SHALL follow.

#### Scenario: Close after a reply
- **WHEN** a library sends a reply and immediately calls `close`
- **THEN** the peer receives the whole reply, then end of stream, and the handler receives one `Closed` with reason `Local`

#### Scenario: Cancelling a dial
- **WHEN** a library calls `close` on a dialled link before its `Opened` event
- **THEN** the connection attempt is abandoned, no `Opened` is delivered, and one `Closed` follows

#### Scenario: Reset
- **WHEN** a library calls `reset` on an open link with bytes still queued
- **THEN** the peer observes a connection reset and the handler receives one `Closed` with reason `Local`

### Requirement: Peer end of stream and half-close
By default, when the peer finishes sending, the provider SHALL transmit the bytes already accepted and then close the link with reason `PeerClosed`. After `set_keep_open_on_eof(link, true)` the provider SHALL instead deliver `PeerEof` once and keep the link open for sending. `shutdown_write(link)` SHALL end the local sending direction once accepted bytes are out; later sends SHALL return `Closed`, and the link SHALL close when the peer has finished too.

#### Scenario: Default behaviour on peer end of stream
- **WHEN** a peer sends a request and shuts down its sending side, and the library has not opted in to keep the link open
- **THEN** bytes the library already sent reach the peer and the handler receives `Closed` with reason `PeerClosed`

#### Scenario: Answering after the peer half-closes
- **WHEN** a library has opted in, the peer half-closes, and the library then sends a reply and calls `shutdown_write`
- **THEN** the handler receives `PeerEof` once after all `Data`, the peer receives the whole reply followed by end of stream, and `Closed` follows

### Requirement: Close reasons are portable
A `Closed` event SHALL carry one of the portable reasons `PeerClosed`, `PeerReset`, `ConnectFailed`, `IdleTimeout`, `HalfCloseTimeout`, `Local`, `Shutdown` or `Error`, or a provider-specific reason carrying a numeric code. A provider MAY close a link on its own policy at any time. A portable library SHALL handle every reason and SHALL treat a provider-specific reason as it treats `Error`.

#### Scenario: The peer resets the connection
- **WHEN** a peer aborts an open link with a TCP reset
- **THEN** the handler receives `Closed` with reason `PeerReset`

#### Scenario: A provider-specific reason reaches a portable library
- **WHEN** a provider closes a link for a reason outside the portable set
- **THEN** the `Closed` event carries the provider-specific reason and its code, and the example client library handles it as it handles `Error`

### Requirement: Time and ticks
A provider SHALL expose `now_ms`, a monotonic millisecond clock that never goes backwards, and SHALL deliver a `Tick` event carrying that clock at least every 100 ms while the worker runs. `tick_by(at_ms)` SHALL cause a `Tick` whose time is at or after `at_ms` to be delivered promptly once the clock reaches `at_ms`. A provider need keep only the earliest outstanding request, which the first such `Tick` satisfies.

#### Scenario: Regular ticks
- **WHEN** a worker runs for one second with no network activity
- **THEN** at least ten `Tick` events are delivered and their times never decrease

#### Scenario: A deadline shorter than the tick period
- **WHEN** a library calls `tick_by(now_ms + 20)`
- **THEN** a `Tick` whose time is at or after the requested time is delivered within a few milliseconds of it, not at the next 100 ms boundary

#### Scenario: Two libraries with different deadlines
- **WHEN** one library requests a tick in 20 ms and another in 50 ms, and each re-requests its own deadline while handling every `Tick`
- **THEN** each library observes a `Tick` at or after its own deadline within a few milliseconds of it

### Requirement: End-of-pass notification
After `want_pass_end` is called on a worker, the provider SHALL deliver exactly one `PassEnd` after the last link event of every pass that delivered at least one link event, and none for a pass that delivered only ticks or nothing. Operations called while handling `PassEnd` SHALL behave as anywhere else, and events they cause SHALL NOT produce a second `PassEnd` for the same pass.

#### Scenario: Batching replies
- **WHEN** a library has requested pass-end and ten requests on ten links arrive in one pass
- **THEN** the handler receives the ten `Data` events and then exactly one `PassEnd`

#### Scenario: An idle pass
- **WHEN** a pass delivers only a `Tick`
- **THEN** no `PassEnd` is delivered

### Requirement: Shutdown is observable
A provider SHALL expose `draining`, which is true once the worker has begun shutting down. Links closed by the provider because of shutdown SHALL receive `Closed` with reason `Shutdown`.

#### Scenario: A server answers during shutdown
- **WHEN** a worker begins shutting down while links are open
- **THEN** `draining` returns true for handlers that run afterwards, and links still open when shutdown completes receive `Closed` with reason `Shutdown`

### Requirement: Scope of the base contract
The base contract SHALL cover TCP byte streams over IPv4 and IPv6, ticks and deadlines, and nothing else. Name resolution, TLS, UDP, Unix sockets, files, signals, cross-thread messaging, and joining two links for forwarding SHALL NOT be required of a provider.

#### Scenario: IPv6 is supported
- **WHEN** a library listens on `[::1]` and dials that address
- **THEN** the link opens and carries data as an IPv4 link does

#### Scenario: A provider without extras conforms
- **WHEN** a provider implements only the operations and events of this specification
- **THEN** it passes the conformance suite
