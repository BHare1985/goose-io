## ADDED Requirements

### Requirement: The descriptor readiness capability is named by its parts
The contract SHALL have an optional capability named descriptor-readiness, made of the operations `watch_descriptor`, `arm` and `unwatch`, the event `Ready`, and the types `Watch` and `Interest`. It SHALL have the declaration `supplies_descriptor_readiness`, the query `has_descriptor_readiness` and the compile-time check `require_descriptor_readiness`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `watch_descriptor` without a compile-time branch is built against an event loop that does not declare descriptor-readiness
- **THEN** the build fails and the error names `supplies_descriptor_readiness` or `watch_descriptor`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `watch_descriptor` only in the branch taken when `goose_io::has_descriptor_readiness` is `Supplied` is built against the core-only loop
- **THEN** it builds, and the library refuses to start, or runs the C client on a thread of its own and reports through `wake_with`

### Requirement: A watch delivers Ready once per arm
`watch_descriptor(fd, interest)` SHALL return a valid `Watch` and arm it for `interest`. The loop SHALL deliver one `Ready { watch, readable, writable, failed }` when the descriptor is ready for any part of the armed interest, or has failed, and SHALL NOT deliver another until `arm` is called again.

#### Scenario: A readable descriptor
- **WHEN** a library watches a descriptor for reading and its peer writes
- **THEN** it receives one `Ready` with `readable` true

#### Scenario: No re-arm, no event
- **WHEN** a library does not call `arm` after a `Ready` and more data arrives
- **THEN** it receives no further `Ready` for the watch

### Requirement: Arm changes what is asked
`arm(watch, interest)` SHALL replace the armed interest and SHALL deliver `Ready` in the next pass if the descriptor is already ready for it. An empty interest SHALL disarm the watch without ending it. `arm` of an ended or invalid watch SHALL return false.

#### Scenario: Asking for write
- **WHEN** a library arms a watch for writing on a descriptor with room to write
- **THEN** it receives `Ready` with `writable` true in the next pass

### Requirement: The library owns the descriptor
The loop SHALL never read, write or close a watched descriptor. `unwatch(watch)` SHALL end the watch at once, with no `Ready` after it, and the library SHALL call it before closing the descriptor. A descriptor already watched, or one the loop cannot watch, SHALL get an invalid `Watch`.

#### Scenario: Unwatch then close
- **WHEN** a library unwatches a descriptor and closes it
- **THEN** no `Ready` is delivered for the watch and the loop's other links are unaffected

#### Scenario: A descriptor watched twice
- **WHEN** a library calls `watch_descriptor` for a descriptor it already watches
- **THEN** it returns an invalid `Watch`

### Requirement: Ready is a library event
`Ready` SHALL be delivered only to the library that made the watch, in the same pass order as link events, and SHALL be followed by `PassEnd` when batching is supplied. When the loop finishes, every watch SHALL end with no further `Ready`.

#### Scenario: A pass with a Ready
- **WHEN** a pass delivers a `Ready` and a `Data`
- **THEN** the pass ends with one `PassEnd` after both
