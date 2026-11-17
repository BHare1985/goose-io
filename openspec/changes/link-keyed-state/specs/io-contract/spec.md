# Spec Delta

## MODIFIED Requirements

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

### Requirement: The core is twelve operations and five events
The core operations SHALL be `listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `now_ms`, `tick_by`, `serve`, `stop` and `draining`. The core events SHALL be `Opened`, `Data`, `Writable`, `Closed` and `Tick`. `listener_port` and `pause_reading` are in the core because a suite that runs both ends of every link on one loop cannot otherwise reach a system-chosen port or make a peer that does not read.

#### Scenario: The core is enough for a client
- **WHEN** the example line client is built against an event loop that supplies only the core
- **THEN** the build succeeds and the client's tests pass

## ADDED Requirements

### Requirement: Slot numbers are dense
An event loop SHALL give a new link a slot freed earlier before it gives a slot it has never used, so that no link's slot is ever as large as the greatest number of links valid at once on that loop. A slot whose generations are used up MAY be retired and not given again. A library MAY therefore size a table by slot to the event loop's peak, and SHALL NOT assume the bound is its own peak of links.

#### Scenario: Slots are reused before new ones are issued
- **WHEN** a library opens eight links, closes all of them, waits for every `Closed`, and opens eight more
- **THEN** every link of the second eight has a slot below eight

#### Scenario: A reused slot has a new generation
- **WHEN** a slot is reused by a new link
- **THEN** the new link's generation differs from the generation of the link that held it before

#### Scenario: The bound is the loop's peak
- **WHEN** a library keeps two links while other libraries on the same event loop hold 99,999 others, and the library then opens another link
- **THEN** that link's slot may be as high as 99,999, and no link's slot reaches 100,001

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

## REMOVED Requirements

### Requirement: Every link event names its owner
**Reason**: The tag and the user value it describes are removed; *A link event is recognised by what the library holds* replaces it.

**Migration**: Stop passing a tag to `listen` and `dial`; find state with a `LinkMap` keyed by the event's link, and tell an accepted link's owner by `Opened.listener`.

## RENAMED Requirements

- FROM: `### Requirement: The core is thirteen operations and five events`
- TO: `### Requirement: The core is twelve operations and five events`

