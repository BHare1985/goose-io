## ADDED Requirements

### Requirement: The name resolution capability has a page
`docs/capabilities/name-resolution.md` SHALL exist with the sections every capability page has, and SHALL explain a lookup from `resolve` to `Resolved`, the order of the addresses and how to try them, and the fallback of a resolver thread with wake. Its examples SHALL be quoted from `examples/capabilities/dial_by_name.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/name-resolution.md`
- **THEN** it says to use name resolution whenever a client is given a host name, and to fall back to a resolver thread with wake on a loop without it

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `resolve` and the other operations and events of name-resolution named under "What it is", and a checked example
