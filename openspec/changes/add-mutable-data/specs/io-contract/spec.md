## ADDED Requirements

### Requirement: The mutable data capability is named by its parts
The contract SHALL have an optional capability named mutable-data, made of the operation `data_mut(link) -> u8[:]`. It SHALL have the declaration `supplies_mutable_data`, the query `has_mutable_data` and the compile-time check `require_mutable_data`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `data_mut` without a compile-time branch is built against an event loop that does not declare mutable-data
- **THEN** the build fails and the error names `supplies_mutable_data` or `data_mut`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `data_mut` only in the branch taken when `goose_io::has_mutable_data` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it copies the bytes into its own buffer and transforms them there

### Requirement: Data mut lends the bytes of the Data being handled
`data_mut(link)` SHALL return the same bytes, in the same order and length, as the `bytes` of the `Data` the loop is delivering for that link, writable and valid until the handler returns. Outside such a handler, or for another link, it SHALL return an empty slice.

#### Scenario: The same bytes
- **WHEN** a library handles a `Data` of 16 bytes and calls `data_mut(link)`
- **THEN** it returns 16 bytes equal to the event's `bytes`

#### Scenario: Outside the handler
- **WHEN** a library calls `data_mut(link)` while handling `Tick`
- **THEN** it returns an empty slice

### Requirement: Writes reach only the library
A write through `data_mut` SHALL change the bytes the event's `bytes` shows for the rest of the handler, and nothing else: not the peer, not a later `Data`, not `peek`, and not another link. When retained-data is also supplied, a `retain` after the write SHALL keep the changed bytes.

#### Scenario: Unmasking in place
- **WHEN** a library XORs each byte of a frame with its mask through `data_mut`
- **THEN** reading the event's `bytes` later in the handler shows the unmasked payload

#### Scenario: Retaining changed bytes
- **WHEN** a loop supplies both capabilities and a library changes bytes then calls `retain`
- **THEN** `retained_bytes` returns the changed bytes
