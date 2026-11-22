## ADDED Requirements

### Requirement: The retained data capability is named by its parts
The contract SHALL have an optional capability named retained-data, made of the operations `retain(link) -> Retained`, `retained_bytes(r) -> const u8[:]`, `send_retained(link, r, offset, len) -> SendStatus`, `release(r)` and `max_retained() -> i64`, and the handle type `Retained`. It SHALL have the declaration `supplies_retained_data`, the query `has_retained_data` and the compile-time check `require_retained_data`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `retain` without a compile-time branch is built against an event loop that does not declare retained-data
- **THEN** the build fails and the error names `supplies_retained_data` or `retain`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `retain` only in the branch taken when `goose_io::has_retained_data` is `Supplied` is built against the core-only loop
- **THEN** it builds, and it copies the bytes into a buffer of its own

### Requirement: Retain keeps the bytes of the Data being handled
`retain(link)` SHALL be valid only while the loop delivers a `Data` for that link, and SHALL return a handle to exactly that event's bytes, which stay valid and unchanged until `release`, also after the link's `Closed`. Outside such a handler, or for another link, it SHALL return an invalid handle.

#### Scenario: Bytes kept across passes
- **WHEN** a library retains a `Data` of 200 bytes and returns
- **THEN** `retained_bytes` returns the same 200 bytes in every later pass until `release`

#### Scenario: Retain outside its handler
- **WHEN** a library calls `retain(link)` while handling `Tick`
- **THEN** it returns an invalid handle and keeps nothing

### Requirement: Retained bytes are bounded
The loop SHALL bound the bytes retained at once by `max_retained()`, a documented configuration. `retain` SHALL return an invalid handle when the bytes would exceed it, and the event's bytes stay valid until the handler returns, so the library can copy them. `release` SHALL return the bytes to the bound at once.

#### Scenario: Over the bound
- **WHEN** `max_retained()` is 4096, 4000 bytes are retained, and a `Data` of 200 bytes is handled
- **THEN** `retain` returns an invalid handle and the library copies the 200 bytes

### Requirement: A retained range can be sent
`send_retained(link, r, offset, len)` SHALL behave as `send` of `len` bytes of the retained bytes from `offset`: all or nothing, with the same `SendStatus` values, and the retained bytes stay valid after it. A range outside the bytes, or an invalid or released handle, SHALL return `TooLarge` or `Closed` and send nothing.

#### Scenario: Passing a request through
- **WHEN** a proxy retains a request and later sends it to a backend with `send_retained`
- **THEN** the backend receives exactly the request's bytes

#### Scenario: A released handle
- **WHEN** `send_retained` is called with a handle that was released
- **THEN** it returns `Closed` and sends nothing

### Requirement: Release ends a retained range
`release(r)` SHALL end the handle, after which `retained_bytes` SHALL return no bytes and the handle SHALL never be given to a later `retain`. A second `release`, or one of an invalid handle, SHALL have no effect.

#### Scenario: A handle after release
- **WHEN** a library releases a handle and calls `retained_bytes` on it
- **THEN** it returns no bytes
