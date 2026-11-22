## ADDED Requirements

### Requirement: The mutable data capability has a page
`docs/capabilities/mutable-data.md` SHALL exist with the sections every capability page has, and SHALL explain which bytes `data_mut` lends, how long they stay writable, what writes do and do not reach, and when changing bytes in place beats copying. Its examples SHALL be quoted from `examples/capabilities/unmask.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/mutable-data.md`
- **THEN** it says to use `data_mut` when every received byte is transformed (unmasking, decryption, translation), and to copy when only a few bytes are kept or the bytes are not changed

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `data_mut` and the other operations and events of mutable-data named under "What it is", and a checked example
