## ADDED Requirements

### Requirement: The transport hints capability has a page
`docs/capabilities/transport-hints.md` SHALL exist with the sections every capability page has, and SHALL explain each hint, what it changes and what it never changes, and when a library would set one per link instead of relying on the loop's configuration. Its examples SHALL be quoted from `examples/capabilities/rpc_and_bulk.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/transport-hints.md`
- **THEN** it says to use a hint when links of one loop want different treatment, and to leave socket options to the loop's configuration when every link wants the same

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `set_hint` and the other operations and events of transport-hints named under "What it is", and a checked example
