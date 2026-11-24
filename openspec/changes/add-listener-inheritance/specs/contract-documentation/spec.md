## ADDED Requirements

### Requirement: The listener inheritance capability has a page
`docs/capabilities/listener-inheritance.md` SHALL exist with the sections every capability page has, and SHALL explain a restart that refuses no connection, step by step, what moves with a listener, and the two ways a process inherits listeners. Its examples SHALL be quoted from `examples/capabilities/graceful_restart.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/listener-inheritance.md`
- **THEN** it says to use inheritance for restarts and upgrades that must not refuse connections, and plain `listen` for a server that can be down for the moment of a restart

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `adopt_listener` and the other operations and events of listener-inheritance named under "What it is", and a checked example
