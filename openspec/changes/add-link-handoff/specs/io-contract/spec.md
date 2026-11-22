## ADDED Requirements

### Requirement: The link handoff capability is named by its parts
The contract SHALL have an optional capability named link-handoff, made of the operations `hand_off(link) -> Ticket`, `adopt(ticket) -> Link` and `drop_ticket(ticket)`, the type `Ticket`, and the close reason `HandedOff`. It SHALL have the declaration `supplies_link_handoff`, the query `has_link_handoff` and the compile-time check `require_link_handoff`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `hand_off` without a compile-time branch is built against an event loop that does not declare link-handoff
- **THEN** the build fails and the error names `supplies_link_handoff` or `hand_off`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `hand_off` only in the branch taken when `goose_io::has_link_handoff` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it serves the link on the loop that accepted it

### Requirement: Hand off takes a link away from its loop
`hand_off(link)` on an open link that is not relayed SHALL return a valid `Ticket` and deliver the link's `Closed` with reason `HandedOff`, after which the link's handle is stale and the connection stays open. For any other link it SHALL return an invalid ticket and change nothing.

#### Scenario: The first loop lets go
- **WHEN** a library hands off an open link
- **THEN** it receives `Closed` with `HandedOff` and the peer sees no end of stream

#### Scenario: A relayed link
- **WHEN** a library calls `hand_off` on a relayed link
- **THEN** it returns an invalid ticket and the relay goes on

### Requirement: Adopt gives the connection a new link
`adopt(ticket)` on a loop of the same kind in the same process, on any thread, SHALL return a link whose `Opened` (with no listener) follows. Bytes accepted before `hand_off` SHALL be sent before any accepted after `adopt`. Bytes received and not delivered SHALL be the new link's first `Data`.

#### Scenario: Order across the move
- **WHEN** the first loop sent a header and handed off, and the second adopts and sends a body
- **THEN** the peer receives the header then the body

#### Scenario: Bytes already received
- **WHEN** the peer sent a request just before the hand-off
- **THEN** the adopting library receives it as its first `Data`

### Requirement: A ticket is used once
A ticket SHALL be adopted at most once. `adopt` of an invalid, used or dropped ticket, or on a loop of another kind, SHALL return an invalid link. `drop_ticket(ticket)` SHALL close the connection as `close` does. Tickets that are not adopted or dropped when their loop is stopped SHALL be closed.

#### Scenario: A ticket adopted twice
- **WHEN** two loops call `adopt` with the same ticket
- **THEN** one gets a link and the other an invalid link

#### Scenario: A ticket no one adopts
- **WHEN** a ticket is dropped
- **THEN** the peer sees end of stream after the bytes accepted before the hand-off

### Requirement: A ticket can cross threads
A `Ticket` SHALL be a value of at most 16 bytes, valid on any thread of the process, so it can be sent in the body of `wake_with` when wake is supplied. A link's settings SHALL NOT move with it: the adopting library sets keep-open, limits and hints while its `Opened` is handled.

#### Scenario: A ticket in a wake
- **WHEN** an acceptor loop sends a ticket in the body of `wake_with` to a worker loop
- **THEN** the worker adopts it from the `Woken` body

#### Scenario: Settings are not carried
- **WHEN** a link with an `Idle` limit is handed off and adopted
- **THEN** the adopted link has no limit until its library sets one
