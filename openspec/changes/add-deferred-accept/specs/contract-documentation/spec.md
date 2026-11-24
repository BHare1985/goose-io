## ADDED Requirements

### Requirement: The deferred accept capability has a page
`docs/capabilities/deferred-accept.md` SHALL exist with the sections every capability page has, and SHALL explain what deferring saves, which protocols it suits (client speaks first), and what happens at the timeout. Its examples SHALL be quoted from `examples/capabilities/deferred_server.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/deferred-accept.md`
- **THEN** it says to defer for protocols where the client always speaks first, and never for ones where the server speaks first (SMTP, a greeting banner), since those clients would wait forever

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `defer_accept` and the other operations and events of deferred-accept named under "What it is", and a checked example
