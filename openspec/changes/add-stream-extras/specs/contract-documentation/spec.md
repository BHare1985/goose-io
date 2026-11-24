## ADDED Requirements

### Requirement: Each stream capability has a page
Each of the files, loans, parts and addresses capabilities SHALL have its page in `docs/capabilities/`, with the sections every capability page has, an example quoted from a built and tested program, and a row in the index.

#### Scenario: The capability page check after this change
- **WHEN** the capability page check runs after the four capabilities are declared
- **THEN** it passes, and it finds `files.md`, `loans.md`, `parts.md` and `addresses.md` with their rows in the index
