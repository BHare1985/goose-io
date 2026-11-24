## ADDED Requirements

### Requirement: The early data capability is named by its parts
The contract SHALL have an optional capability named early-data, made of the operations `dial_with_data(address, connect_ms, first) -> Link`, `max_early_data() -> i64` and `accept_early_data(listener, on) -> bool`. It SHALL have the declaration `supplies_early_data`, the query `has_early_data` and the compile-time check `require_early_data`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `dial_with_data` without a compile-time branch is built against an event loop that does not declare early-data
- **THEN** the build fails and the error names `supplies_early_data` or `dial_with_data`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `dial_with_data` only in the branch taken when `goose_io::has_early_data` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it dials with `dial` and sends the first request at `Opened`

### Requirement: Dial with data opens a link whose first bytes are given
`dial_with_data(address, connect_ms, first)` SHALL dial as `dial` does and SHALL send `first` as the link's first bytes, before any byte a later `send` gives, whether the loop sends them with the opening or after it. A dial that fails SHALL send none of them and end as a failed `dial` does.

#### Scenario: The request arrives
- **WHEN** a client dials with data to a listening server
- **THEN** the server receives the bytes of `first` before any other bytes of the link

#### Scenario: A send after the dial
- **WHEN** a client calls `send` on the link right after `dial_with_data`
- **THEN** its bytes arrive after the bytes of `first`

### Requirement: Early data is bounded
`max_early_data()` SHALL be a documented bound no larger than `max_send()`. A `first` longer than it SHALL be refused as a dial on a finished loop is: the invalid link is returned and no connection is started.

#### Scenario: Too much early data
- **WHEN** a client calls `dial_with_data` with more bytes than `max_early_data()`
- **THEN** it returns the invalid link and nothing is dialled

### Requirement: Early bytes may be repeated
Bytes a loop sends with a connection's opening MAY reach the peer's application more than once. A loop SHALL send early only the bytes of `first`, never bytes of a later `send`.

#### Scenario: A later send is never early
- **WHEN** a client calls `send` before the link opens
- **THEN** those bytes are sent only after the link is open

### Requirement: A listener accepts early data only when asked
A listener SHALL accept bytes that arrive with a connection's opening only after `accept_early_data(listener, true)`, which SHALL return whether the loop applied it. Such bytes SHALL be delivered as the link's first `Data`, after `Opened`. Without it, the peer sends them after the handshake.

#### Scenario: A listener that did not ask
- **WHEN** a client dials with data to a listener that never called `accept_early_data`
- **THEN** the server still receives the bytes, after the link opens, as its first `Data`
