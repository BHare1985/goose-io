## ADDED Requirements

### Requirement: The link handoff capability has a page
`docs/capabilities/link-handoff.md` SHALL exist with the sections every capability page has, and SHALL explain what moves with the link and what does not, how a ticket crosses threads, and when handing off beats sharing a listener or relaying. Its examples SHALL be quoted from `examples/capabilities/acceptor_workers.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/link-handoff.md`
- **THEN** it says to hand off when a connection must be served on a loop chosen after it was accepted, and to share a listener when any loop can serve any connection

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `hand_off` and the other operations and events of link-handoff named under "What it is", and a checked example
