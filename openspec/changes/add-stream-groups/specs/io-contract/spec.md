## MODIFIED Requirements

### Requirement: The contract is a core and groups of extras
The contract SHALL be a core, which every event loop supplies, and fourteen groups of extras: half-close, sizing, abort, inspection, batching and unix, and relay, peek, revoke, wake, files, loans, parts and addresses. An event loop MAY supply any group. A rule that belongs to a group SHALL bind only an event loop that supplies that group, and a rule of the core SHALL NOT depend on any group. No group SHALL replace an operation or event of the core: a group adds an operation, an event or an address form beside them.

#### Scenario: A loop that supplies only the core
- **WHEN** an event loop supplies the core and none of the groups
- **THEN** it conforms to the core, and a library that uses only the core runs on it unchanged

#### Scenario: A library uses an extra the loop lacks
- **WHEN** a library that calls `send2` is built against an event loop that does not supply the sizing group, or a library that calls `relay` is built against one that does not supply the relay group
- **THEN** the build fails and the error names `send2` or `relay`

#### Scenario: An event the loop never delivers
- **WHEN** an event loop does not supply the half-close group, the peek group or the wake group
- **THEN** it never delivers `PeerEof`, `Input` or `Woken`, and a library's handling of those events is never run

#### Scenario: A library that needs no group runs on a loop that supplies many
- **WHEN** a library that uses only the core is built against a loop that supplies every group
- **THEN** it builds and behaves as it does on a loop that supplies only the core

### Requirement: Each group is named and checked on its own
The groups SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`), batching (`PassEnd`), unix (the address form `unix:/path`), relay (`relay`, `relayed_bytes`), peek (`peek`, `wait_input`, `Input`), revoke (`discard_unsent`, `write_deadline`), wake (`waker`, `wake`, `Woken`), files (`open_file`, `close_file`, `send_file`), loans (`loan`, `loan_bytes`, `send_loan`, `release_loan`), parts (`send_parts`) and addresses (`local_address`, `original_destination`). The contract package SHALL offer a compile-time check for the core and for each group that has operations, each naming every operation of its part. Batching has only an event, and unix has only an address form, and so neither has a check.

#### Scenario: The core check
- **WHEN** an event loop's root program calls the core check
- **THEN** it compiles if the loop supplies every operation of the core with the contract's types, and otherwise the error names the first operation that is missing

#### Scenario: A group check
- **WHEN** an event loop that supplies the abort group calls the abort check
- **THEN** it compiles, and an event loop without `reset` calling it gets an error naming `reset`

#### Scenario: A check of a new group
- **WHEN** an event loop that lacks `wait_input` calls `require_peek`
- **THEN** the program fails to build and the error names `wait_input`

#### Scenario: An operation that was removed
- **WHEN** a library calls `set_user` or `user`, or passes a tag to `listen` or `dial`
- **THEN** the build fails and the error names the call

## ADDED Requirements

### Requirement: Relay joins two links inside the loop
The relay group SHALL offer `relay(a, b)`. It SHALL join two open links of the loop that are not relayed and return `Started`, after which the loop carries every byte received on one link to the other, in order and in both directions, and delivers no `Data` or `Writable` for either link. It SHALL return `NotOpen` when either link has not opened, `Closed` when either is closing, closed or stale, and `AlreadyRelayed` when either is joined already, and in each case join nothing.

#### Scenario: Bytes cross in both directions
- **WHEN** a library relays two links whose peers each send a message and then end their streams
- **THEN** each peer receives the other's message intact, each link receives one `Closed` with reason `PeerClosed`, and no `Data` was delivered for either link after `relay`

#### Scenario: A link that cannot be relayed
- **WHEN** `relay` is called with a link that is still dialling, a link that is closing, a stale link, or a link already relayed
- **THEN** it returns `NotOpen`, `Closed`, `Closed` or `AlreadyRelayed` respectively and neither link is affected

### Requirement: A relay holds back and ends as a pair
A relay SHALL carry backpressure: a link whose peer does not read SHALL hold the other link's reading back, and the loop's memory for the pair SHALL stay bounded. The end of one link's stream SHALL end the other link's sending after the bytes carried before it, and when both streams have ended each link SHALL receive one `Closed` with reason `PeerClosed`. A reset, an error or a loop limit on either link SHALL end both links, each with one `Closed` and no further event.

#### Scenario: A peer that does not read
- **WHEN** one end of a relayed pair sends a megabyte and the other end's peer never reads
- **THEN** the sending peer is held back, the loop's memory for the pair stays bounded, and `relayed_bytes` reports only the bytes that were carried

#### Scenario: Half-close passes through
- **WHEN** one peer ends its stream and the other peer then sends bytes
- **THEN** the first peer's partner sees the end of stream after the bytes sent before it, the other direction still carries bytes, and the links end when both streams have ended

#### Scenario: A reset ends both links
- **WHEN** one peer of a relayed pair resets its connection
- **THEN** both links receive one `Closed` and no other event, and the loop holds nothing for either afterwards

### Requirement: A relayed link is owned by the relay
The relay group SHALL offer `relayed_bytes(link)`, which returns the bytes carried from that link to its partner and 0 for a link never relayed or stale. While a link is relayed, `send`, `send2` and `send_room` SHALL return `Closed` and 0, as after `shutdown_write` (the relay owns the sending of the link); `pause_reading`, `set_keep_open_on_eof` and `shutdown_write` SHALL have no effect; and `close` and `reset` SHALL end both links of the pair.

#### Scenario: Sending on a relayed link
- **WHEN** a library calls `send` on a link it has relayed
- **THEN** `send` returns `Closed`, `send_room` returns 0 where the sizing group is supplied, and the link is not ended on that account

#### Scenario: Closing one end of a relay
- **WHEN** a library calls `close` on one link of a relayed pair
- **THEN** both links end, each with one `Closed`, reason `Local`

#### Scenario: The bytes carried
- **WHEN** 1000 bytes have been carried from one link to its partner
- **THEN** `relayed_bytes` of that link returns 1000

### Requirement: Peek shows unread bytes without consuming them
The peek group SHALL offer `peek(link)`, which returns the bytes that have arrived on an open link and have not been delivered as `Data`, valid until the handler returns, and consumes nothing. It SHALL return no bytes for a link that is not open or is stale.

#### Scenario: Peek consumes nothing
- **WHEN** a library peeks at a link twice before releasing it
- **THEN** both calls show the same bytes, and the bytes arrive afterwards as `Data` exactly once

#### Scenario: Peek on a stale link
- **WHEN** a library calls `peek` with a link whose `Closed` has been handled
- **THEN** no bytes are returned and nothing else is affected

### Requirement: Peek waits for enough bytes and then releases them
The peek group SHALL offer `wait_input(link, n)` and the event `Input { link, available }`. With `n` greater than 0 it SHALL withhold `Data` until at least `n` bytes have arrived or the peer's stream has ended and then deliver one `Input`; `Data` SHALL stay withheld until `wait_input(link, 0)`, which SHALL deliver the held bytes unchanged and in order as `Data`. A link SHALL hold no more bytes than the loop's bound for a link and SHALL not read past it.

#### Scenario: Bytes are decided on, then delivered
- **WHEN** a library calls `wait_input(link, 5)`, a peer sends 3 bytes, then 4 more, and the library calls `peek` in the handler of `Input` and then `wait_input(link, 0)`
- **THEN** `Input` is delivered once after the second send, `peek` shows all 7 bytes, and the same 7 bytes then arrive as `Data` in order

#### Scenario: The peer ends before enough bytes
- **WHEN** a library calls `wait_input(link, 100)` and the peer sends 10 bytes and ends its stream
- **THEN** `Input` is delivered with `available` 10, and the library still receives `PeerEof` or `Closed` as the link's settings say after it calls `wait_input(link, 0)`

### Requirement: Revoke takes back unsent bytes
The revoke group SHALL offer `discard_unsent(link)`. It SHALL drop every byte the loop accepted on the link and has not handed to the transport, return how many it dropped, and treat any `Writable` owed to the link as if those bytes had been sent. Bytes already handed to the transport SHALL not be recalled.

#### Scenario: Unsent bytes are dropped
- **WHEN** a library has been refused with `Full` and then calls `discard_unsent`
- **THEN** it receives the number of bytes that were queued, a later `send` of the same size returns `Sent`, and the peer receives only what had been written before the call

### Requirement: A write deadline stops writes at a time
The revoke group SHALL offer `write_deadline(link, at_ms)`. From the moment the loop's clock is at or after `at_ms` the loop SHALL write no further byte on the link, answer `send` with `Closed`, and end the link with reason `Local`; the clock SHALL be read at each write and not taken from the start of the pass. A later call SHALL replace the deadline, 0 SHALL remove it, and on a relayed link the deadline SHALL bind the relay's writes in both directions.

#### Scenario: Nothing is written after the deadline
- **WHEN** a library sets a write deadline and bytes accepted before it are still queued when the clock reaches it
- **THEN** no byte is written after the deadline, the link ends with reason `Local`, and `send` returns `Closed`

#### Scenario: The deadline is moved
- **WHEN** a library sets a write deadline, then replaces it with a later time before the first passes
- **THEN** writes continue until the later time

### Requirement: Wake delivers a message from another thread
The wake group SHALL offer `waker()`, `wake(waker, value)` and the event `Woken { value }`. `waker()` SHALL return a fixed-size handle that may be copied to any thread. `wake` SHALL be callable from any thread and SHALL not block, and a wake on a finished loop SHALL have no effect.

#### Scenario: A wake from another thread
- **WHEN** another thread calls `wake(waker, 7)` while the loop is idle
- **THEN** the loop delivers `Woken { value: 7 }` once, promptly, on its own thread

#### Scenario: A wake on a finished loop
- **WHEN** a thread calls `wake` after `serve` has returned
- **THEN** it returns without blocking and no event is delivered

### Requirement: Wakes are delivered in order and lost by no pass
The loop SHALL deliver one `Woken` for each `wake`, on the loop's thread, in the order one thread made them, and SHALL not lose a wake while it is serving or draining. `Woken` SHALL carry no link and SHALL be offered to every library as `Tick` and `PassEnd` are.

#### Scenario: Wakes keep their order
- **WHEN** one thread calls `wake` with 1, 2 and 3
- **THEN** the loop delivers `Woken` with 1, 2 and 3 in that order, and none is lost

### Requirement: A file can be opened for sending
The files group SHALL offer `open_file(path)` and `close_file(file)`. `open_file` SHALL return an opaque `File` handle and the file's size in bytes, or an invalid handle when the file cannot be opened, and SHALL block the loop on nothing but the open itself. A file closed while a send of it is accepted SHALL remain readable by that send until it completes.

#### Scenario: A file that does not exist
- **WHEN** `open_file` is called with a path that does not exist
- **THEN** it returns an invalid handle, and `send_file` with it returns `Closed`

### Requirement: A file is sent as a range
The files group SHALL offer `send_file(link, file, offset, len)`, which SHALL behave as `send` of the `len` bytes of the file from `offset`: all or nothing, with the same `SendStatus` values, the same `Full` and `Writable` rules and the same order with other sends on the link. A range outside the file SHALL be refused with `TooLarge`.

#### Scenario: A file is sent
- **WHEN** a library opens a file of 100 KiB and sends it to a peer with `send_file`
- **THEN** the peer receives exactly the file's bytes, in order, and a `send` before and after it arrives before and after

#### Scenario: A range past the end
- **WHEN** `send_file` is called with `offset` and `len` that extend past the file's end
- **THEN** it returns `TooLarge` and sends nothing

### Requirement: A loan is a buffer the loop lends
The loans group SHALL offer `loan(size)`, `loan_bytes(loan)` and `release_loan(loan)`. `loan` SHALL return a handle to a buffer of at least `size` bytes owned by the loop, or an invalid handle when the loop has none to lend; `loan_bytes` returns the buffer for the library to fill; `release_loan` returns it. A loop SHALL bound the buffers it has lent, so that a library that never releases cannot make memory grow without limit.

#### Scenario: Loans are bounded
- **WHEN** a library takes loans and never releases them
- **THEN** `loan` eventually returns an invalid handle and the loop's memory does not grow beyond its bound

### Requirement: A loan is sent without a copy
The loans group SHALL offer `send_loan(link, loan, len)`, which SHALL behave as `send` of the first `len` bytes of the buffer: all or nothing, with the same `SendStatus` values and the same `Full` and `Writable` rules. On `Sent` the loop owns the buffer and the handle is stale; on any other result the library keeps the loan. A loop MAY send the bytes without copying them.

#### Scenario: A loan is sent
- **WHEN** a library takes a loan, fills it with 1 KiB and sends it
- **THEN** the peer receives those bytes, and `send_loan` returned `Sent`

#### Scenario: A refused loan is kept
- **WHEN** `send_loan` returns `Full`
- **THEN** the library still holds the loan, receives one `Writable`, and a second `send_loan` of the same loan returns `Sent`

### Requirement: Send parts takes any number of parts as one send
The parts group SHALL offer `send_parts(link, parts)`, where `parts` is a list of byte ranges. It SHALL behave as one `send` of the ranges joined: its size for `Full` and `TooLarge` is the sum of the lengths, it takes every part or none, and a list longer than the loop's bound returns `TooLarge`.

#### Scenario: Three parts arrive joined
- **WHEN** a library sends three parts with `send_parts`
- **THEN** the peer receives their bytes in order with nothing between them

#### Scenario: All or nothing
- **WHEN** the sum of the parts does not fit in the room of the link
- **THEN** `send_parts` returns `Full`, no part is taken, and one `Writable` follows when the whole sum would fit

### Requirement: Addresses report the local end
The addresses group SHALL offer `local_address(link)`, which returns the loop's own end of the link as an `Address` in the contract's text form, valid inside the handler of `Closed`, and empty for a link that has not opened, a stale link and a link on a `unix:` path.

#### Scenario: The local end of a link
- **WHEN** a library asks for `local_address` of an accepted link on a listener bound to `127.0.0.1:port`
- **THEN** it returns `127.0.0.1:port` as text

#### Scenario: A stale handle
- **WHEN** it is called with a link whose `Closed` has been handled
- **THEN** it returns an empty address

### Requirement: Addresses report the original destination
The addresses group SHALL offer `original_destination(link)`, which returns the address the peer connected to before any redirection by the system (a transparent proxy), and the same text as `local_address` when there was none.

#### Scenario: No redirection
- **WHEN** a library asks for `original_destination` of a link that was never redirected
- **THEN** it returns the same text as `local_address`

### Requirement: Input is a link event and Woken is for every library
`Input` SHALL be a link event for the link it names, recognised by a library as it recognises `Data`. `Woken` SHALL carry no link and SHALL be offered to every library, as `Tick` and `PassEnd` are. The `Event` type SHALL grow by these two variants, and a library that matches on `Event` without a catch-all arm SHALL name them to build.

#### Scenario: A library claims only the Input of its own link
- **WHEN** two libraries run on one loop and one calls `wait_input` on its link
- **THEN** the `Input` event is claimed by that library only, and the other treats it as not handled

#### Scenario: A match without a catch-all
- **WHEN** a library matches on `Event` and names neither `Input` nor `Woken` and has no catch-all arm
- **THEN** the build fails and the error names the missing variant
