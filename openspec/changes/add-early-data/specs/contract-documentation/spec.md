## ADDED Requirements

### Requirement: The early data capability has a page
`docs/capabilities/early-data.md` SHALL exist with the sections every capability page has, and SHALL explain what early data saves, the replay rule and which requests are safe to send early, and the server opt-in. Its examples SHALL be quoted from `examples/capabilities/early_get.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/early-data.md`
- **THEN** it says to dial with data for a repeat-safe first request to a server the client talks to often, and never for a request that changes state

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `dial_with_data` and the other operations and events of early-data named under "What it is", and a checked example
