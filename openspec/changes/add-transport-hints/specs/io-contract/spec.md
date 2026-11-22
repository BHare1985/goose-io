## ADDED Requirements

### Requirement: The transport hints capability is named by its parts
The contract SHALL have an optional capability named transport-hints, made of the operation `set_hint(link, hint, value) -> bool` and the type `Hint` (`NoDelay`, `Coalesce`, `KeepAlive`, `SendLowWater`, `PacingRate`). It SHALL have the declaration `supplies_transport_hints`, the query `has_transport_hints` and the compile-time check `require_transport_hints`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `set_hint` without a compile-time branch is built against an event loop that does not declare transport-hints
- **THEN** the build fails and the error names `supplies_transport_hints` or `set_hint`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `set_hint` only in the branch taken when `goose_io::has_transport_hints` is `Supplied` is built against the core-only loop
- **THEN** it builds, and every link is sent with the loop's configured options

### Requirement: A hint never changes what is delivered
A loop that supplies transport hints SHALL deliver the same bytes in the same order, with the same results of `send`, `send2` and `close`, and the same events apart from the time of `Writable`, whether or not a hint is set. A hint SHALL only change when accepted bytes are handed to the transport and when `Writable` is delivered.

#### Scenario: A hint the loop cannot apply
- **WHEN** a loop on a system without `TCP_NOTSENT_LOWAT` is asked for `SendLowWater`
- **THEN** `set_hint` returns false, and the link behaves as if no hint were set

#### Scenario: A hint does not reorder
- **WHEN** a link with `Coalesce` set sends a header in one `send` and a body in the next
- **THEN** the peer receives the header then the body, unchanged

### Requirement: Set hint takes a hint and a value
`set_hint(link, hint, value)` SHALL apply to an open link and replace an earlier value of the same hint; value 0 SHALL turn a hint off. It SHALL return true when the loop applied the hint and false when it did not, for a link that is not open, a stale handle, or a negative value.

#### Scenario: A stale handle
- **WHEN** `set_hint` is called with a handle of a closed link
- **THEN** it returns false and changes nothing

#### Scenario: Turning a hint off
- **WHEN** `set_hint(link, KeepAlive, 0)` follows `set_hint(link, KeepAlive, 30)`
- **THEN** the link sends no keepalive probes

### Requirement: A coalescing link is flushed by the end of the pass
On a link with `Coalesce` set, the loop MAY hold accepted bytes to fill segments, and SHALL hand every byte accepted in a pass to the transport no later than the end of that pass (after `PassEnd` when batching is supplied), and at once on `close` or `shutdown_write`.

#### Scenario: Bytes are not held across a pass
- **WHEN** a coalescing link sends 10 bytes in a pass and nothing more
- **THEN** the bytes reach the transport before the loop waits for events again

### Requirement: Send low water gates Writable
On a link with `SendLowWater` set to `n`, the loop SHALL deliver an owed `Writable` only when fewer than `n` accepted bytes wait to be handed to the transport, and `send_room`, when sizing is supplied, SHALL not exceed what keeps the waiting bytes under `n`.

#### Scenario: Writable waits for the queue to drain
- **WHEN** a link with `SendLowWater` 1000 was refused with `Full` and 5000 bytes wait
- **THEN** `Writable` is delivered only once fewer than 1000 wait

### Requirement: Pacing and keepalive are bounded by the loop
`PacingRate` SHALL limit the rate at which the link's bytes are handed to the transport to at most `value` bytes per second, averaged over a second. `KeepAlive` SHALL make the loop probe an idle link after `value` seconds and close it with reason `Error` when the probes fail.

#### Scenario: A paced link
- **WHEN** a link paced at 1000 bytes a second sends 5000 bytes at once
- **THEN** the peer receives them over no less than four seconds of the loop's clock

#### Scenario: A dead peer
- **WHEN** a link with `KeepAlive` set has a peer that vanished without a reset
- **THEN** the link gets `Closed` with reason `Error` after the probes fail
