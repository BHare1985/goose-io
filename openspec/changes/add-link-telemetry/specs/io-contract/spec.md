## ADDED Requirements

### Requirement: The link telemetry capability is named by its parts
The contract SHALL have an optional capability named link-telemetry, made of the operation `link_stats(link) -> LinkStats` and the type `LinkStats`. It SHALL have the declaration `supplies_link_telemetry`, the query `has_link_telemetry` and the compile-time check `require_link_telemetry`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `link_stats` without a compile-time branch is built against an event loop that does not declare link-telemetry
- **THEN** the build fails and the error names `supplies_link_telemetry` or `link_stats`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `link_stats` only in the branch taken when `goose_io::has_link_telemetry` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it decides from its own counters of bytes sent and received

### Requirement: Link stats reports the transport's state
`link_stats(link)` SHALL return, for a link from `Opened` until its `Closed` has been handled: bytes accepted by `send`, bytes handed to the transport, bytes received, bytes in flight, bytes the transport holds unread, smoothed round-trip time and its variation in microseconds, retransmits, and delivery rate in bytes per second.

#### Scenario: A link in use
- **WHEN** a library reads `link_stats` after sending and receiving on an open link
- **THEN** the byte counts are those of the link, and the counters never decrease

### Requirement: An unknown field is minus one
A field the loop cannot measure on its system SHALL be -1, never 0. A dialling or stale link SHALL report every field as -1. The byte counters accepted, handed over and received SHALL always be known for an open link.

#### Scenario: A loop without round-trip times
- **WHEN** a loop on a system with no round-trip measurement reports `link_stats`
- **THEN** the round-trip fields are -1 and the byte counters are known

#### Scenario: A stale handle
- **WHEN** `link_stats` is called with a handle of a link whose `Closed` was handled
- **THEN** every field is -1
