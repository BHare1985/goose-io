## ADDED Requirements

### Requirement: A loop declares each capability it supplies
An event loop SHALL declare, for each capability it supplies, that it supplies it, as a fact about the loop's type that is known when a program is built. A loop SHALL NOT declare a capability it does not supply. A loop that declares nothing for a capability SHALL be taken not to supply it. The declaration SHALL NOT be a run-time value. The contract package SHALL offer, for every capability, a query that answers whether a loop supplies it when the program is built.

#### Scenario: A loop that supplies relay
- **WHEN** a program asks at compile time whether an event loop that declares relay supplies relay
- **THEN** the answer is that it does

#### Scenario: A loop that says nothing
- **WHEN** a program asks the same of an event loop that declares nothing about relay, including one written before declarations existed
- **THEN** the answer is that it does not, and the program builds

#### Scenario: Declaration has no run-time cost
- **WHEN** a library that asks about a capability is built against a loop
- **THEN** the program it builds contains only the branch for the loop's answer, and no test of the answer at run time

### Requirement: A declaration agrees with the operations
A loop that declares a capability SHALL supply every operation of that capability with the contract's types. A program that builds a loop whose declaration says it supplies a capability, and passes it to that capability's check or to a library that takes the branch of that capability, SHALL fail to build when an operation is missing, and the error SHALL name the operation.

#### Scenario: A declaration without the operations
- **WHEN** an event loop declares relay but has no `relayed_bytes`, and its root program calls `require_relay`
- **THEN** the build fails and the error names `relayed_bytes`

#### Scenario: A library meets a false declaration
- **WHEN** a library that relays when the loop declares relay is built against a loop that declares relay but has no `relay`
- **THEN** the build fails and the error names `relay`

### Requirement: A library may use a capability optionally
A library SHALL be able to use a capability only when the loop supplies it, branching on the loop's declaration at compile time so that the branch for a capability the loop lacks is not compiled. The library's header SHALL name the capabilities it needs and, separately, those it uses when the loop supplies them. On a loop without the capability it SHALL behave correctly, differing only as its header states.

#### Scenario: A forwarder relays where it can
- **WHEN** the example forwarder is built against the in-memory loop, which supplies relay, and a client sends through it to a backend
- **THEN** the bytes reach the backend, the forwarder receives no `Data` for either link, and `relayed_bytes` counts them

#### Scenario: The same forwarder copies where it must
- **WHEN** the same forwarder source is built against an event loop that supplies only the core
- **THEN** it builds, the bytes reach the backend intact and in order, and the forwarder receives them as `Data` and sends them on

#### Scenario: A header that hides an optional use
- **WHEN** a library calls an operation of a capability inside the branch of its declaration and its header does not name the capability under what it uses when supplied
- **THEN** the inspection of library headers fails and names the library and the capability

### Requirement: A wrapping loop passes on what it declares
An event loop that wraps another SHALL declare a capability only when it supplies that capability itself or passes it through from the loop it wraps, and SHALL declare no capability it does not pass through. A wrapper that passes a capability through SHALL be able to take its declaration from the loop it wraps, so that one wrapper source declares relay over a loop that supplies relay and does not declare it over one that does not.

#### Scenario: A wrapper over a loop with relay
- **WHEN** the test wrapper loop that forwards relay wraps the in-memory loop
- **THEN** a program that asks whether the wrapper supplies relay is told that it does

#### Scenario: The same wrapper over a loop without relay
- **WHEN** the same wrapper wraps the core-only loop
- **THEN** it is told that it does not, and a library that uses relay optionally builds over it and copies

### Requirement: Each capability is checked on its own
For the core and for each capability that has operations, the contract package SHALL offer a compile-time check that names every operation of its part, and the check of a capability SHALL also require the loop's declaration of it. Batching has only an event and unix only an address form, so neither has a check.

#### Scenario: The core check
- **WHEN** an event loop's root program calls the core check
- **THEN** it compiles if the loop supplies every operation of the core with the contract's types, and otherwise the error names the first operation that is missing

#### Scenario: A capability check
- **WHEN** an event loop that supplies and declares the abort capability calls the abort check
- **THEN** it compiles, and an event loop without `reset` calling it gets an error naming `reset`

#### Scenario: A check of a capability with several operations
- **WHEN** an event loop that declares peek but lacks `wait_input` calls `require_peek`
- **THEN** the program fails to build and the error names `wait_input`

#### Scenario: A check on a loop that does not declare the capability
- **WHEN** an event loop that has every operation of relay but no declaration of relay calls `require_relay`
- **THEN** the program fails to build and the error names the relay declaration

### Requirement: A capability added later names its parts in a requirement of its own
A capability added to the contract after the eleven SHALL be named, with its operations, events and address forms, by a requirement of its own, and SHALL have a declaration and a query like every capability. Adding a capability SHALL NOT need a change to a requirement of another capability, so that capabilities can be added independently of one another.

#### Scenario: Two capabilities proposed at once
- **WHEN** two changes each add a capability
- **THEN** neither modifies a requirement the other modifies, and they can be applied in either order

### Requirement: The contract is a core and optional capabilities
The contract SHALL be a core, which every event loop supplies, and optional capabilities, each named with its parts by a requirement of this specification. An event loop MAY supply any capability. A rule of a capability SHALL bind only a loop that supplies it, and a rule of the core SHALL NOT depend on any capability. No capability SHALL replace an operation or event of the core: it adds an operation, an event or an address form beside them.

#### Scenario: A loop that supplies only the core
- **WHEN** an event loop supplies the core and none of the capabilities
- **THEN** it conforms to the core, and a library that uses only the core runs on it unchanged

#### Scenario: A library requires a capability the loop lacks
- **WHEN** a library that calls `send2` without a compile-time branch is built against an event loop that does not supply the sizing capability, or a library that calls `relay` that way is built against one that does not supply the relay capability
- **THEN** the build fails and the error names `send2` or `relay`

#### Scenario: A library uses a capability the loop lacks optionally
- **WHEN** a library that calls `relay` only in the branch taken when the loop declares relay is built against an event loop that does not supply relay
- **THEN** the build succeeds and the library takes its other branch at run time on every link

#### Scenario: An event the loop never delivers
- **WHEN** an event loop does not supply the half-close capability, the peek capability, the wake capability or the limits capability
- **THEN** it never delivers `PeerEof`, `Input`, `Woken` or `Expired`, and a library's handling of those events is never run

#### Scenario: A library that needs no capability runs on a loop that supplies many
- **WHEN** a library that uses only the core is built against a loop that supplies every capability
- **THEN** it builds and behaves as it does on a loop that supplies only the core

### Requirement: Each capability is named by its parts
The capabilities SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`), batching (`PassEnd`), unix (the address form `unix:/path`), relay (`relay`, `relayed_bytes`), peek (`peek`, `wait_input`, `discard_input`, `Input`), revoke (`discard_unsent`, `write_deadline`), wake (`waker`, `wake`, `wake_with`, `Woken`) and limits (`set_limit`, `Expired`).

#### Scenario: An operation that was removed
- **WHEN** a library calls `set_user` or `user`, or passes a tag to `listen` or `dial`
- **THEN** the build fails and the error names the call

### Requirement: The unix capability is the address form unix:/path
An event loop that supplies the unix capability SHALL accept `unix:/path` in `listen` and `dial`, naming a connection-oriented stream socket, with the same operations, events, results and rules as for a TCP address. The capability SHALL add no operation, event or type. An event loop that does not supply it SHALL treat the text as any address it does not accept: `listen` returns an error of kind `BadAddress`, and `dial` ends with one `Closed` of reason `ConnectFailed` with kind `BadAddress`.

#### Scenario: A listener and a dial on a path
- **WHEN** a library on an event loop that supplies the unix capability calls `listen("unix:/run/x.sock", tag)` and the same loop calls `dial("unix:/run/x.sock", tag2, 0)`
- **THEN** the listen succeeds, both links receive `Opened` (the accepted one with the listener's tag and handle, the dialled one with no listener), and bytes sent on one arrive on the other in order

#### Scenario: A failure the system reports uses an existing kind
- **WHEN** a library dials a well-formed path that the system refuses (nothing listens, or access is denied)
- **THEN** the `Closed` event's reason is `ConnectFailed` with the kind the contract already has for that failure (`Refused` or `Denied`, or `Other` when the event loop cannot tell), and no kind specific to Unix sockets exists

#### Scenario: A loop without the capability
- **WHEN** a library calls `dial("unix:/run/x.sock", tag, 0)` or `listen("unix:/run/x.sock", tag)` on an event loop that does not supply the unix capability
- **THEN** the dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress` and no `Opened`, and `listen` returns an error of kind `BadAddress`

## MODIFIED Requirements

### Requirement: The contract exposes no operating-system primitives
Contract types and operations SHALL NOT expose file descriptors, socket address structures, poll masks, or any other operating-system or backend object. Addresses SHALL be text: numeric `ip:port` for IPv4 and `[ip]:port` for IPv6, and, for an event loop that supplies the unix capability, `unix:/path` or `unix:///path`. An IPv6 zone identifier is not part of an address: text that contains one SHALL be treated as malformed.

#### Scenario: A zone identifier is rejected
- **WHEN** a library dials `[fe80::1%eth0]:80`, and listens on it
- **THEN** the dial ends with one `Closed` with reason `ConnectFailed`, and `listen` returns an error of kind `BadAddress`

#### Scenario: An event loop without descriptors conforms
- **WHEN** an event loop that has no file descriptors at all implements the contract in memory
- **THEN** every operation and event of the contract is expressible and the conformance suite runs against it

### Requirement: The contract states its version
The contract SHALL publish its version as a major and minor number, 0.1 for this specification. While the major number is zero, a minor increase MAY change or remove behaviour. From major version one, a minor increase SHALL only add. An event loop SHALL state the contract version it conforms to and the capabilities it supplies.

#### Scenario: A library reads the version
- **WHEN** a program reads the contract's version
- **THEN** it obtains the major and minor numbers of the contract it was built against

### Requirement: Listening
`listen(address)` SHALL start accepting TCP connections and return a listener handle, or an error naming its kind and a loop-specific code. Each accepted connection SHALL produce `Opened` carrying the listener's handle. `listener_port(listener)` SHALL return the bound port, including one the system chose for port zero. An event loop that supplies the inspection capability SHALL provide `stop_listening(listener)`, which stops new connections without closing accepted links.

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
- **WHEN** a library on an event loop with the inspection capability calls `stop_listening` while a link accepted from that listener is open
- **THEN** new connection attempts are no longer accepted and the open link continues to deliver and send data

### Requirement: Listener handles are never reused
A listener handle SHALL identify one listener for the life of its loop: an event loop SHALL NOT give the same handle to a later listener. An operation on the handle of a listener that has stopped, or on a handle the loop never issued, SHALL have no effect, and `listener_port` SHALL return 0 for it. When an event loop has no unused handle left, `listen` SHALL fail with `NoResources`; it SHALL NOT start again from an old handle. A listener SHALL be used only on the loop that created it.

#### Scenario: A stale listener handle cannot reach a newer listener
- **WHEN** a library on an event loop with the inspection capability stops a listener, listens again on the same address, and then calls `stop_listening` with the first handle
- **THEN** the second listener has a different handle and keeps accepting connections, and `listener_port` of the first handle returns 0

#### Scenario: Handles run out and do not wrap
- **WHEN** an event loop has issued every listener handle it can
- **THEN** the next `listen` returns an error of kind `NoResources` and no listener

### Requirement: A link reports its peer's address
An event loop that supplies the inspection capability SHALL provide `peer_address(link)`, which returns the remote endpoint of an open, write-shut or closing link as numeric text in the form `dial` accepts, and an empty value for a dialling link, for a link whose `Closed` has been delivered, and for a stale or invalid handle. IPv6 text SHALL be lower case with the longest run of two or more zero capabilities written as `::`. The value SHALL be available from the link's `Opened` event until its `Closed` event has been delivered.

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

### Requirement: A failed dial says why
A `ConnectFailed` reason SHALL carry a kind: `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress` or `Other`. An event loop SHALL report `BadAddress` for text that is not an address of a form it accepts (a numeric address, and `unix:/path` or `unix:///path` where it supplies the unix capability), `TimedOut` when `connect_ms` elapses, and `NoResources` when it has no link left. For every other failure it SHALL translate what its system reports, and report `Other` when it cannot tell. No system error number is part of the reason.

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

### Requirement: Two parts can be sent as one
An event loop that supplies the sizing capability SHALL provide `send2(link, first, second)`, which behaves as one `send` of the two byte ranges joined in that order: both are taken and `Sent` is returned, or neither is taken. Its size for `Full`, `TooLarge` and `send_room` SHALL be the sum of the two lengths.

#### Scenario: A header and a body
- **WHEN** a library calls `send2` with a 20-byte header and a 100-byte body on an open, idle link
- **THEN** `send2` returns `Sent` and the peer receives the 120 bytes in order with nothing between them

#### Scenario: Neither part is taken when both do not fit
- **WHEN** `send_room` is smaller than the two parts together but larger than the first
- **THEN** `send2` returns `Full`, the peer receives none of the first part, and one `Writable` follows once room has opened

### Requirement: Send backpressure is explicit and bounded
An event loop SHALL bound the bytes it holds unsent for each link. `max_send` SHALL report the largest single send it can accept: at least 4096 bytes, one value for the whole loop. A larger send SHALL return `TooLarge`, and one that does not fit now `Full`. The sizing capability's `send_room(link)` SHALL return the bytes a send would accept now, at most `max_send`, and 0 for a link that cannot send.

#### Scenario: An oversized send never fits
- **WHEN** a library sends more than `max_send` bytes in one call
- **THEN** `send` returns `TooLarge` and no `Writable` is delivered for it

#### Scenario: A reader that never reads does not grow memory
- **WHEN** a library keeps offering bytes to a peer that reads nothing, sending only when `send` accepts
- **THEN** the event loop's memory for that link stays within its per-link bound

#### Scenario: No room on a link that cannot send
- **WHEN** a library on an event loop with the sizing capability asks for `send_room` of a link before its `Opened`, after `close`, after `shutdown_write`, or with a stale handle
- **THEN** it obtains 0

### Requirement: Closing
`close(link)` SHALL transmit the bytes already accepted and then end the connection cleanly, without waiting for the peer to finish; on a link that has not opened it SHALL cancel the dial. An event loop that supplies the abort capability SHALL also provide `reset(link)`, which ends the link at once, discarding unsent bytes, so the peer observes an abort. After either call, sends SHALL return `Closed` and the only further event for the link SHALL be exactly one `Closed` with reason `Local`.

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
- **WHEN** a library on an event loop with the abort capability calls `reset` on an open link with bytes still queued
- **THEN** the peer's link ends with reason `PeerReset` and the handler receives one `Closed` with reason `Local` for the reset link

### Requirement: Peer end of stream and half-close
When the peer finishes sending, an event loop SHALL send the bytes already accepted and close the link with `PeerClosed`. The half-close capability adds `set_keep_open_on_eof(link, keep)`, `shutdown_write(link)` and `PeerEof`: with keep set the loop SHALL deliver `PeerEof` once, after every `Data`, and keep the link open; `shutdown_write` SHALL end local sending once accepted bytes are out (later sends return `Closed`), and the link SHALL close when the peer has finished too.

#### Scenario: Default behaviour on peer end of stream
- **WHEN** a peer sends a request and shuts down its sending side, and the library has not opted in to keep the link open
- **THEN** bytes the library already sent reach the peer and the handler receives `Closed` with reason `PeerClosed`

#### Scenario: Answering after the peer half-closes
- **WHEN** a library on an event loop with the half-close capability has opted in, the peer half-closes, and the library then sends a reply and calls `shutdown_write`
- **THEN** the handler receives `PeerEof` once after all `Data`, the peer receives the whole reply followed by end of stream, and `Closed` follows

### Requirement: End-of-pass notification
An event loop MAY supply the batching capability. One that does SHALL deliver exactly one `PassEnd`, last, in every pass that delivered a link event, and none in a pass of only ticks or nothing: no link event or `Tick` of that pass SHALL follow it, and calls made while handling it SHALL NOT cause a second one. A library SHALL NOT depend on `PassEnd` for correctness: it is for batching only.

#### Scenario: Batching replies
- **WHEN** ten requests on ten links arrive in one pass on an event loop with the batching capability
- **THEN** the handler receives the ten `Data` events and then exactly one `PassEnd`

#### Scenario: PassEnd is last
- **WHEN** one pass delivers a `Tick` and link events on an event loop with the batching capability
- **THEN** `PassEnd` is delivered after all of them, and the application offers it to every library once

#### Scenario: An idle pass
- **WHEN** a pass delivers only a `Tick`
- **THEN** no `PassEnd` is delivered

#### Scenario: A loop without batching
- **WHEN** an event loop does not supply the batching capability
- **THEN** it never delivers `PassEnd`, and every library that sends as it handles each event still works

### Requirement: Event loops can be layered
An event loop SHALL be able to wrap another event loop, transforming the bytes of some or all links, and present the same contract to libraries above it. Nothing in the contract SHALL prevent the wrapper from delaying `Opened`, changing the size of what is sent or received, or closing a link with a loop-specific reason. A wrapper SHALL supply at least the capabilities it passes through.

#### Scenario: A transforming wrapper conforms
- **WHEN** a wrapper that alters every byte on the way out and restores it on the way in is placed over a conforming event loop
- **THEN** the conformance suite passes against the wrapper for the capabilities the wrapper supplies, with no change to the suite or to the event loop underneath

#### Scenario: A library cannot tell
- **WHEN** the example client and server libraries run over the wrapper
- **THEN** their tests pass with no change to either library's source

### Requirement: What the contract covers
The contract SHALL cover TCP byte streams over IPv4 and IPv6, stream sockets at a path in the unix capability, ticks and deadlines, and running and stopping one loop, and nothing else. Name resolution, TLS, UDP, files, signals, cross-thread messaging, starting several loops, and joining two links for forwarding SHALL NOT be required of an event loop. Nothing in a capability SHALL be required of an event loop that does not supply the capability.

#### Scenario: IPv6 is covered
- **WHEN** a library listens on `[::1]` and dials that address
- **THEN** the link opens and carries data as an IPv4 link does

#### Scenario: An event loop without extras conforms to the core
- **WHEN** an event loop implements only the operations and events of the core
- **THEN** it passes the core of the conformance suite

### Requirement: A Unix socket path is absolute and bounded
A Unix socket address SHALL be malformed, and so reported as `BadAddress`, when its path is empty, is not absolute, is longer than 103 bytes, holds a NUL byte, or begins with `@` as an abstract name would. An event loop SHALL NOT resolve or normalise a path.

#### Scenario: Malformed paths
- **WHEN** a library on an event loop that supplies the unix capability dials `unix:`, `unix:run/x.sock`, `unix:@name`, and a `unix:` address whose path is 104 bytes long
- **THEN** each dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress`

#### Scenario: The longest path
- **WHEN** a library on an event loop that supplies the unix capability listens on a path of 103 bytes and dials it
- **THEN** both links receive `Opened`

### Requirement: unix:///path is a spelling of unix:/path
An event loop that supplies the unix capability SHALL also accept the URL spelling `unix:///path`, and it SHALL name the same path as `unix:/path`, so the two spellings are one endpoint. The path follows `unix://` and SHALL begin with a single `/`: an authority (`unix://host/x`, `unix://x`) and a doubled slash (`unix:////x`) are malformed. The spelling SHALL NOT be decoded or split: `%`, `?` and `#` are bytes of the path. The limit of 103 bytes is on the path.

#### Scenario: The URL spelling names the same path
- **WHEN** a library on an event loop that supplies the unix capability calls `listen("unix:/run/x.sock", tag)` and the same loop calls `dial("unix:///run/x.sock", tag2, 0)`
- **THEN** both links receive `Opened`, and a `listen` on `unix:///run/x.sock` returns an error of kind `AddressInUse`

#### Scenario: An authority or a doubled slash
- **WHEN** a library on an event loop that supplies the unix capability dials `unix://host/x.sock`, `unix://x.sock`, `unix:////x.sock` and `unix://`
- **THEN** each dial ends with exactly one `Closed` of reason `ConnectFailed` with kind `BadAddress`

#### Scenario: Nothing is decoded
- **WHEN** a library listens on `unix:///run/a%20b.sock` and dials `unix:/run/a%20b.sock`
- **THEN** the dial opens, and a dial to `unix:/run/a b.sock` ends with `ConnectFailed` of kind `Refused`

#### Scenario: A held path is held under either spelling
- **WHEN** a library listens on `unix:/run/a.sock`, then on `unix:///run/a.sock`
- **THEN** the second `listen` returns an error of kind `AddressInUse`

### Requirement: A Unix link has no peer address text
An event loop that supplies both the unix and the inspection capabilities SHALL return the empty value from `peer_address` for any link made on a Unix path, because `Address` holds a numeric endpoint of at most 56 bytes and the peer of an accepted Unix connection has no name.

#### Scenario: No peer text
- **WHEN** a library on such an event loop listens on a Unix path, dials it, and asks `peer_address` of both links after `Opened`
- **THEN** each value is empty

### Requirement: Sending has one result in each link state
`send` and `send2` SHALL return `NotOpen` on a dialling link; `Sent`, `Full` or `TooLarge` on an open link, or `Closed` when the event loop has begun to end it; and `Closed` on a write-shut, closing or ended link. `send_room` SHALL be 0 in every state but open.

#### Scenario: One link in each state
- **WHEN** a library sends 10 bytes on one link while it is dialling, while it is open, after calling `close`, and after its `Closed`
- **THEN** `send` returns `NotOpen`, `Sent`, `Closed` and `Closed` in turn

#### Scenario: Sending on a write-shut link
- **WHEN** a library on an event loop with the half-close capability calls `shutdown_write` on an open link and then sends on it
- **THEN** `send` returns `Closed`, and with the sizing capability `send2` returns `Closed` and `send_room` returns 0

### Requirement: A Closed send result is final
Once `send` or `send2` has returned `Closed` for a link, sending on it SHALL stay ended: every later `send` and `send2` SHALL return `Closed`, `send_room` SHALL return 0, and no `Writable` SHALL be delivered for it. When the library had called none of `shutdown_write`, `close` and `reset` on the link, the result SHALL also mean that the event loop is ending the link, and its `Closed` event SHALL follow with no further call.

#### Scenario: The peer goes away
- **WHEN** a library's `send` returns `Closed` on a link it has neither closed nor shut, after the link's peer closed its end
- **THEN** every later `send` on the link returns `Closed`, no `Writable` is delivered for it, and its `Closed` event follows

#### Scenario: A refused send then a Closed result
- **WHEN** a library is refused with `Full`, and a later send on the same link returns `Closed`
- **THEN** no `Writable` is delivered for the link, and its `Closed` event follows

#### Scenario: After shutdown a Closed result concerns only sending
- **WHEN** a library on an event loop with the half-close capability calls `shutdown_write` on an open link, a send on it returns `Closed`, and the peer then sends bytes and later finishes
- **THEN** the library receives those bytes as `Data`, no `Writable`, and the link's `Closed` only after the peer has finished

### Requirement: Ending a link has one result in each link state
`close` and `reset` on a dialling link SHALL abandon the attempt and lead to one `Closed` with reason `Local` and no `Opened`. On an open or write-shut link they SHALL end it as *Closing* states. On a closing or ended link they SHALL have no effect and SHALL NOT cause a second `Closed`. `shutdown_write` SHALL have an effect only on an open link.

#### Scenario: Close twice
- **WHEN** a library calls `close` on an open link and calls `close` on it again before its `Closed` is delivered
- **THEN** the link receives exactly one `Closed`, with reason `Local`

#### Scenario: Reset a dial in progress
- **WHEN** a library on an event loop with the abort capability calls `reset` on a dialling link
- **THEN** no `Opened` is delivered for it and it receives one `Closed` with reason `Local`

#### Scenario: Shutdown before the link opens
- **WHEN** a library on an event loop with the half-close capability calls `shutdown_write` on a dialling link and the link then opens
- **THEN** a send after `Opened` returns `Sent`: the call had no effect

#### Scenario: Close after shutdown
- **WHEN** a library on an event loop with the half-close capability calls `shutdown_write` on an open link and then `close`
- **THEN** the link receives no further `Data` or `PeerEof` and exactly one `Closed`, with reason `Local`

#### Scenario: Reset after close
- **WHEN** a library on an event loop with the abort capability calls `close` and then `reset` on the same link before its `Closed`
- **THEN** the link receives exactly one `Closed`, with reason `Local`

### Requirement: Keep-open is configured no later than Opened
`set_keep_open_on_eof` SHALL be recorded when called on a dialling link or while handling the link's `Opened`, and the setting SHALL apply from the moment that handler returns. A call made later SHALL have no effect, whether or not the peer has finished. An event loop that observed the peer's end of stream before then SHALL act on it only after the `Opened` handler has returned, as the setting says.

#### Scenario: Keep open set while dialling
- **WHEN** a library on an event loop with the half-close capability calls `set_keep_open_on_eof(link, true)` on a dialling link, and the peer sends bytes and finishes as soon as the link opens
- **THEN** the library receives `Opened`, the `Data`, and one `PeerEof`, and the link stays open for sending

#### Scenario: Keep open set while handling Opened
- **WHEN** a library on an event loop with the half-close capability calls `set_keep_open_on_eof(link, true)` while handling the `Opened` of an accepted link, and the peer sends bytes and finishes
- **THEN** the library receives the `Data` and one `PeerEof`, and the link stays open for sending

#### Scenario: A late call has no effect
- **WHEN** a library on an event loop with the half-close capability calls `set_keep_open_on_eof(link, true)` while handling the link's first `Data`, after its `Opened` handler has returned, and the peer then finishes
- **THEN** no `PeerEof` is delivered and the link receives `Closed` with reason `PeerClosed`

#### Scenario: An end of stream that arrives before Opened is handled
- **WHEN** the peer of a dialled link sends bytes and finishes before the library's `Opened` handler for the link has run, and the library calls `set_keep_open_on_eof(link, true)` in that handler
- **THEN** the library receives the `Data` and one `PeerEof`, and the link stays open for sending

### Requirement: Each operation says how it completes
Every operation SHALL take its effect and give its result when it returns. Only these SHALL have a later notification: `dial` (one `Opened` or `Closed`), `close` and `reset` (one `Closed`), a send refused with `Full` (one `Writable` or `Closed`), `tick_by` (a `Tick` at or after the earliest outstanding request, which may answer several calls), and `stop` (`serve` returning). No other event SHALL report an operation's result.

#### Scenario: Shutdown is complete when it returns
- **WHEN** a library on an event loop with the half-close capability calls `shutdown_write` on an open link and sends on it in the same handler
- **THEN** that send returns `Closed`, and no event is delivered for the link because of the call other than its eventual `Closed`

#### Scenario: Pausing is complete when it returns
- **WHEN** a library calls `pause_reading(link, true)` while handling a `Data` event, and the peer goes on sending
- **THEN** no further `Data` is delivered for the link until it is resumed, and no event reports the pause

#### Scenario: One Tick may answer several requests
- **WHEN** a library calls `tick_by(now_ms + 20)` and `tick_by(now_ms + 50)` in one handler
- **THEN** a `Tick` at or after the earlier time is delivered before the next regular `Tick`, and that one `Tick` may be the only notification for both calls

### Requirement: Relay joins two links inside the loop
The relay capability SHALL offer `relay(a, b)`. It SHALL join two open links of the loop that are not relayed and return `Started`, after which the loop carries every byte received on one link to the other, in order and in both directions, and delivers no `Data` or `Writable` for either link. It SHALL return `NotOpen` when either link has not opened, `Closed` when either is closing, closed or stale, and `AlreadyRelayed` when either is joined already, and in each case join nothing.

#### Scenario: Bytes cross in both directions
- **WHEN** a library relays two links whose peers each send a message and then end their streams
- **THEN** each peer receives the other's message intact, each link receives one `Closed` with reason `PeerClosed`, and no `Data` was delivered for either link after `relay`

#### Scenario: A link that cannot be relayed
- **WHEN** `relay` is called with a link that is still dialling, a link that is closing, a stale link, or a link already relayed
- **THEN** it returns `NotOpen`, `Closed`, `Closed` or `AlreadyRelayed` respectively and neither link is affected

### Requirement: A relayed link is owned by the relay
The relay capability SHALL offer `relayed_bytes(link)`, which returns the bytes carried from that link to its partner and 0 for a link never relayed or stale. While a link is relayed, `send`, `send2` and `send_room` SHALL return `Closed` and 0, as after `shutdown_write` (the relay owns the sending of the link); `pause_reading`, `set_keep_open_on_eof` and `shutdown_write` SHALL have no effect; and `close` and `reset` SHALL end both links of the pair.

#### Scenario: Sending on a relayed link
- **WHEN** a library calls `send` on a link it has relayed
- **THEN** `send` returns `Closed`, `send_room` returns 0 where the sizing capability is supplied, and the link is not ended on that account

#### Scenario: Closing one end of a relay
- **WHEN** a library calls `close` on one link of a relayed pair
- **THEN** both links end, each with one `Closed`, reason `Local`

#### Scenario: The bytes carried
- **WHEN** 1000 bytes have been carried from one link to its partner
- **THEN** `relayed_bytes` of that link returns 1000

### Requirement: Peek shows unread bytes without consuming them
The peek capability SHALL offer `peek(link)`, which returns the bytes that have arrived on an open link and have not been delivered as `Data`, valid until the handler returns, and consumes nothing. It SHALL return no bytes for a link that is not open or is stale.

#### Scenario: Peek consumes nothing
- **WHEN** a library peeks at a link twice before releasing it
- **THEN** both calls show the same bytes, and the bytes arrive afterwards as `Data` exactly once

#### Scenario: Peek on a stale link
- **WHEN** a library calls `peek` with a link whose `Closed` has been handled
- **THEN** no bytes are returned and nothing else is affected

### Requirement: Peek waits for enough bytes and then releases them
The peek capability SHALL offer `wait_input(link, n)` and the event `Input { link, available }`. With `n` greater than 0 it SHALL withhold `Data` until at least `n` bytes have arrived or the peer's stream has ended and then deliver one `Input`; `Data` SHALL stay withheld until `wait_input(link, 0)`, which SHALL deliver the held bytes unchanged and in order as `Data`. `Input` SHALL carry the number of bytes held and not the bytes: they stay with the loop until `peek` or `relay`.

#### Scenario: Bytes are decided on, then delivered
- **WHEN** a library calls `wait_input(link, 5)`, a peer sends 3 bytes, then 4 more, and the library calls `peek` in the handler of `Input` and then `wait_input(link, 0)`
- **THEN** `Input` is delivered once after the second send, `peek` shows all 7 bytes, and the same 7 bytes then arrive as `Data` in order

#### Scenario: The peer ends before enough bytes
- **WHEN** a library calls `wait_input(link, 100)` and the peer sends 10 bytes and ends its stream
- **THEN** `Input` is delivered with `available` 10, and the library still receives `PeerEof` or `Closed` as the link's settings say after it calls `wait_input(link, 0)`

### Requirement: Revoke takes back unsent bytes
The revoke capability SHALL offer `discard_unsent(link)`. It SHALL drop every byte the loop accepted on the link and has not handed to the transport, return how many it dropped, and treat any `Writable` owed to the link as if those bytes had been sent. Bytes already handed to the transport SHALL not be recalled.

#### Scenario: Unsent bytes are dropped
- **WHEN** a library has been refused with `Full` and then calls `discard_unsent`
- **THEN** it receives the number of bytes that were queued, a later `send` of the same size returns `Sent`, and the peer receives only what had been written before the call

### Requirement: A write deadline stops writes at a time
The revoke capability SHALL offer `write_deadline(link, at_ms)`. From the moment the loop's clock is at or after `at_ms` the loop SHALL write no further byte on the link, answer `send` with `Closed`, and end the link with reason `Local`; the clock SHALL be read at each write and not taken from the start of the pass. A later call SHALL replace the deadline, 0 SHALL remove it, and on a relayed link the deadline SHALL bind the relay's writes in both directions.

#### Scenario: Nothing is written after the deadline
- **WHEN** a library sets a write deadline and bytes accepted before it are still queued when the clock reaches it
- **THEN** no byte is written after the deadline, the link ends with reason `Local`, and `send` returns `Closed`

#### Scenario: The deadline is moved
- **WHEN** a library sets a write deadline, then replaces it with a later time before the first passes
- **THEN** writes continue until the later time

### Requirement: Wake delivers a message from another thread
The wake capability SHALL offer `waker()`, `wake(waker, value)` and the event `Woken { value }`. `waker()` SHALL return a fixed-size handle that may be copied to any thread. `wake` SHALL be callable from any thread and SHALL not block, and a wake on a finished loop SHALL have no effect.

#### Scenario: A wake from another thread
- **WHEN** another thread calls `wake(waker, 7)` while the loop is idle
- **THEN** the loop delivers `Woken { value: 7 }` once, promptly, on its own thread

#### Scenario: A wake on a finished loop
- **WHEN** a thread calls `wake` after `serve` has returned
- **THEN** it returns without blocking and no event is delivered

### Requirement: A limit tells the library that a link has run too long in a state
The limits capability SHALL offer `set_limit(link, kind, ms)` and the event `Expired { link, limit }`, with `kind` and `limit` one of `Idle`, `Silent`, `Stalled`, `HalfOpen` and `Age`. With `ms` greater than 0 on an open link the loop SHALL deliver `Expired` with that kind once, when the link has been in the kind's state for `ms` of the loop's clock. A second call for the same kind SHALL replace it, `ms` 0 SHALL turn it off, and the kinds SHALL be independent of one another.

#### Scenario: Two kinds on one link
- **WHEN** a library arms `Idle` with 1000 and `Age` with 60000 on a link and the peer sends nothing
- **THEN** `Expired` with `Idle` is delivered at 1000 ms, and `Expired` with `Age` at 60000 ms if the link is still open

#### Scenario: Replacing and turning off
- **WHEN** a library arms `Idle` with 1000 and then arms it with 5000, or with 0, before 1000 ms have passed
- **THEN** `Expired` is delivered 5000 ms after the second call in the first case and never in the second

### Requirement: The peek capability drops held bytes
The peek capability SHALL offer `discard_input(link, n)`, which SHALL drop the first `n` held bytes of an open link that is not relayed, at most as many as `peek` shows, and return how many it dropped; for any other link it SHALL return 0. It SHALL deliver no `Input` and no `Data`, and the bytes after the dropped ones SHALL stay held in order.

#### Scenario: Dropping held bytes
- **WHEN** a library holds 7 bytes with `wait_input`, calls `discard_input(link, 3)` and then `discard_input(link, 100)`
- **THEN** the first call returns 3 and `peek` shows the last 4 bytes, the second returns 4 and `peek` shows none, and no `Input` is delivered by either

## REMOVED Requirements

### Requirement: The contract is a core and groups of extras
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The contract is a core and optional capabilities`.

### Requirement: Each group is named and checked on its own
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `Each capability is named by its parts`.

### Requirement: The unix group is the address form unix:/path
**Reason**: Restated with "capability" in place of "group"; a scenario's name changes, which a modification cannot carry.
**Migration**: See the ADDED requirement `The unix capability is the address form unix:/path`.

## RENAMED Requirements

- FROM: `### Requirement: The peek group drops held bytes`
- TO: `### Requirement: The peek capability drops held bytes`
