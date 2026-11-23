# Spec Delta

## Purpose

A view gives one library its own `io` over a shared event loop, and a registry records which library owns each link and listener, so that a library can act only on what it made and is shown only the events of its own links.

## ADDED Requirements

### Requirement: A view presents the library operations
A view SHALL supply every operation of the core except `serve` and `stop`, and each operation of a group that the event loop beneath it supplies, with the contract's types and results, so that a library written against the contract runs on it unchanged.

#### Scenario: A library runs unchanged through a view
- **WHEN** the example echo server, line server and line client are run on a view over the in-memory event loop with their existing tests
- **THEN** every test passes without a change to the library

#### Scenario: A library cannot stop the loop
- **WHEN** a library calls `stop` or `serve` on a view
- **THEN** the build fails and the error names the operation

### Requirement: Ownership comes from provenance
The owner of a link SHALL be the library whose view returned it from `dial`, or, for an accepted link, the library whose view returned the listener that its `Opened` names. The owner of a listener SHALL be the library whose view returned it from `listen`. A claim made by a library SHALL NOT change an owner.

#### Scenario: A link the library dialled for itself
- **WHEN** a library dials through its view and the application never sees the handle
- **THEN** the registry names that library as the owner of every event of the link

#### Scenario: An accepted link
- **WHEN** a library listens through its view and a peer connects
- **THEN** the registry names that library as the owner of the accepted link from its `Opened`

### Requirement: What a library does not own does not exist for it
An operation of a view on a link its library does not own SHALL behave as on an invalid link: `send` and `send2` return `Closed`, `send_room` returns 0, `peer_address` returns the empty value, and every other operation has no effect. `stop_listening` on a listener it does not own SHALL have no effect and `listener_port` SHALL return 0.

#### Scenario: A forged or leaked handle
- **WHEN** a library calls `send`, `close`, `pause_reading` and `peer_address` with a link that another library owns
- **THEN** `send` returns `Closed`, `peer_address` is empty, and the other library's link is unaffected

#### Scenario: A guessed handle
- **WHEN** a library calls `send` with every slot and a range of generations that no view returned to it
- **THEN** every call returns `Closed` and no link of any library receives a byte

#### Scenario: Another library's listener
- **WHEN** a library calls `stop_listening` and `listener_port` with a listener that another library owns
- **THEN** the listener keeps accepting and `listener_port` returns 0

### Requirement: An event reaches only its owner
For an event about a link the registry SHALL name the library that owns the link, and for a `Tick` or `PassEnd` every library. An application that calls only the named library SHALL show no library the bytes or the existence of a link it does not own.

#### Scenario: Two libraries on one loop
- **WHEN** two libraries each hold a link and data arrives on the first library's link
- **THEN** the registry names the first library, the second library is not called, and it observes no event

#### Scenario: Ticks go to every library
- **WHEN** the event loop delivers a `Tick`
- **THEN** the registry names every library

### Requirement: Ownership ends with the link
An entry SHALL end when the application reports the link's `Closed` event as handled. A handle kept after that SHALL belong to no library, and a slot that a new link reuses SHALL carry the owner of the new link.

#### Scenario: A kept handle after Closed
- **WHEN** a library keeps the handle of a closed link and another library's new link reuses its slot
- **THEN** the first library's calls with the old handle have no effect on the new link

### Requirement: A link nobody owns is named as such
An accepted link whose listener no view returned SHALL have no owner, and the registry SHALL name no library for its events, so that the application decides what to do with it.

#### Scenario: A listener made outside any view
- **WHEN** the application listens on the real loop and a peer connects
- **THEN** the registry names no library for the accepted link's events

### Requirement: The cost of a view is stated
A view SHALL add to an operation one table lookup and nothing else, and the registry SHALL name the owner of an event with one lookup. The cost SHALL be measured against offering each event to every library in turn, and recorded in `bench/README.md`.

#### Scenario: The overhead is recorded
- **WHEN** the benchmark is run
- **THEN** `bench/README.md` states the cost of an operation through a view, and of routing an event, with the machine and the compiler version
