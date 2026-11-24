## ADDED Requirements

### Requirement: The shared listen capability has a page
`docs/capabilities/shared-listen.md` SHALL exist with the sections every capability page has, and SHALL explain how connections are spread, what happens to connections waiting on a listener that stops, and when sharing is better than handing links off. Its examples SHALL be quoted from `examples/capabilities/loop_per_core.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/shared-listen.md`
- **THEN** it says to share listening when each loop on its own thread can serve any connection, and to hand links off when one loop must see every connection first

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `listen_shared` and the other operations and events of shared-listen named under "What it is", and a checked example
