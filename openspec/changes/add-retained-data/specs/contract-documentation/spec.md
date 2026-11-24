## ADDED Requirements

### Requirement: The retained data capability has a page
`docs/capabilities/retained-data.md` SHALL exist with the sections every capability page has, and SHALL explain what retaining keeps and for how long, the bound and what to do when `retain` fails, and when retaining beats copying. Its examples SHALL be quoted from `examples/capabilities/frame_reassembly.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/retained-data.md`
- **THEN** it says to retain when bytes must outlive the handler and are large or many, and to copy when they are small, since a retained buffer may hold a whole receive buffer for a few bytes

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `retain` and the other operations and events of retained-data named under "What it is", and a checked example
