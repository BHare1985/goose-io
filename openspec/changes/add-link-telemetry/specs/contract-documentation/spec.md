## ADDED Requirements

### Requirement: The link telemetry capability has a page
`docs/capabilities/link-telemetry.md` SHALL exist with the sections every capability page has, and SHALL explain every field and when it is unknown, how often reading it is cheap, and what decisions it supports. Its examples SHALL be quoted from `examples/capabilities/least_rtt.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/link-telemetry.md`
- **THEN** it says to read telemetry to choose or shed by measured transport state, and to use `Stalled` and `Idle` limits instead when the question is only whether a link is moving

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `link_stats` and the other operations and events of link-telemetry named under "What it is", and a checked example
