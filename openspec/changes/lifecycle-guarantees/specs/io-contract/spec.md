# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
