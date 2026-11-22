## ADDED Requirements

### Requirement: The peek group drops held bytes
The peek group SHALL offer `discard_input(link, n)`, which SHALL drop the first `n` held bytes of an open link that is not relayed, at most as many as `peek` shows, and return how many it dropped; for any other link it SHALL return 0. It SHALL deliver no `Input` and no `Data`, and the bytes after the dropped ones SHALL stay held in order.

#### Scenario: Dropping held bytes
- **WHEN** a library holds 7 bytes with `wait_input`, calls `discard_input(link, 3)` and then `discard_input(link, 100)`
- **THEN** the first call returns 3 and `peek` shows the last 4 bytes, the second returns 4 and `peek` shows none, and no `Input` is delivered by either
