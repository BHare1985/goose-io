## ADDED Requirements

### Requirement: The descriptor readiness capability has a page
`docs/capabilities/descriptor-readiness.md` SHALL exist with the sections every capability page has, and SHALL explain one-shot readiness and re-arming, who owns the descriptor, how a C library's add/remove callbacks map onto `arm` and `unwatch`, and what it costs a loop. Its examples SHALL be quoted from `examples/capabilities/foreign_client.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/descriptor-readiness.md`
- **THEN** it says to use descriptor readiness to host a C library that owns its sockets, and never for links the library could open with `dial`, which keep the contract's guarantees

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `watch_descriptor` and the other operations and events of descriptor-readiness named under "What it is", and a checked example
