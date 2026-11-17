## ADDED Requirements

### Requirement: The loop attaches nothing to a link
The epoll event loop SHALL offer the operations and deliver the events of contract 0.3 only: `listen(address)`, `dial(address, connect_ms)`, and events that carry the link (and, for `Opened`, the listener that accepted it), with no tag and no user value and no operation that sets or reads one. A library SHALL find its state from the link of an event.

#### Scenario: A library on the loop uses no tag
- **WHEN** the example line server and line client run on the loop with no tag assigned by the application
- **THEN** each handles only the events of its own links, and the conformance checks that an accepted link names its listener and that a dial that fails at once is found by its link pass

#### Scenario: An operation that was removed does not exist
- **WHEN** a library calls `set_user` or passes a tag to `listen` or `dial` on the loop
- **THEN** the build fails and the error names the call

### Requirement: Slots are dense and held until Closed has been handled
The epoll event loop SHALL give a new link a freed slot before it gives a slot it has never used, and SHALL free a slot only when every handler of its link's `Closed` has returned. A slot whose generations are used up MAY be retired.

#### Scenario: Freed slots are reused first
- **WHEN** a program opens eight links on the loop, closes them all, waits for every `Closed`, and opens eight more
- **THEN** every link of the second eight has a slot below eight

#### Scenario: A slot is not reused inside the handler of its Closed
- **WHEN** a handler receives `Closed` for a link and opens a new link before it returns
- **THEN** the new link does not take the slot of the link being closed, including when the closed link was a dial that failed inside `dial`

### Requirement: An extension's own identity for a link is its own state
An extension of the epoll event loop that keys data on a link (a route's lease, a deadline, a policy tag) SHALL keep it in per-slot state that the extension owns, indexed by the link's slot and checked against its generation, and the loop SHALL NOT carry it in any event or operation of the contract. A hook that decides about a link SHALL receive the link's slot.

#### Scenario: An extension refuses a send by slot
- **WHEN** an extension reports that a link is no longer allowed, identified by its slot, and a library then sends on that link
- **THEN** no bytes are transmitted and the link closes with a `LoopSpecific` reason, and no tag appears in any event the library receives
