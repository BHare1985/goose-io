# contract-documentation Specification

## Purpose
Documentation of the contract's capabilities for the people who write libraries: what each capability is, when to use it, how it is commonly used, and checked examples of its use, in one page per capability that a check keeps complete.

## Requirements

### Requirement: Every capability has a page
For every capability the contract declares, the repository SHALL have a page at `docs/capabilities/<name>.md`, where `<name>` is the capability's name as the contract spells it. A capability SHALL NOT be added to the contract without its page.

#### Scenario: A capability in code
- **WHEN** the contract package declares the relay capability
- **THEN** `docs/capabilities/relay.md` exists

#### Scenario: A capability added without its page
- **WHEN** a change adds a capability's declaration to `goose_io.goose` and no page for it
- **THEN** the capability page check fails and names the capability

### Requirement: A page has a fixed shape
Every capability page SHALL have these sections, in this order: "What it is", "When to use it", "How it is commonly used", "Examples", "Required or optional", "Supplied by" and "See also". "What it is" SHALL name every operation and event of the capability and link to the capability's normative section of `docs/contract.md`. "When to use it" SHALL also say when not to use it and what a library does on a loop without it.

#### Scenario: A page missing a section
- **WHEN** a capability page has no "When to use it" section
- **THEN** the capability page check fails and names the page and the section

#### Scenario: A page that leaves out an operation
- **WHEN** the peek page's "What it is" does not name `discard_input`
- **THEN** the capability page check fails and names the page and `discard_input`

### Requirement: Examples on a page are checked code
Every capability page SHALL have at least one example in its "Examples" section, and every example SHALL be a `source:` or `excerpt:` block of a file that the repository builds and tests. An example SHALL show the capability in a common use: a library or a test, not only the operation's signature.

#### Scenario: An example that drifts from its code
- **WHEN** an example program quoted on a page changes and the page does not
- **THEN** the document check fails and names the page and the file

#### Scenario: A page with no example
- **WHEN** a capability page's "Examples" section has prose and no checked block
- **THEN** the capability page check fails and names the page

#### Scenario: Every quoted example is tested
- **WHEN** the tests of the repository run
- **THEN** every file that a capability page quotes is built, and every one that is a program or a test is run

### Requirement: A page says how the capability is required or used optionally
The "Required or optional" section of every page SHALL show how a library requires the capability (its `require_<name>` check and its header line) and, unless the capability cannot be used optionally, how a library uses it only when the loop supplies it (the `has_<name>` query and its branch), with what the library does on the other path.

#### Scenario: A capability used optionally
- **WHEN** a reader opens the relay page
- **THEN** it shows the `// Uses if supplied:` header line and the branch on `goose_io::has_relay`, quoted from the forward example, and says that the library copies on a loop without relay

#### Scenario: A capability that is not worth using optionally
- **WHEN** a capability's other path would be the whole behaviour the capability gives, as for unix addresses
- **THEN** the page says so and shows only the required use

### Requirement: A page says which loops supply the capability
The "Supplied by" section of every page SHALL name every event loop in the repository and say for each whether it supplies the capability. It SHALL name known event loops outside the repository that state the capability among those they pass, and link to the mapping documents of candidate loops that record a mechanism for it.

#### Scenario: The core-only loop
- **WHEN** a reader opens any capability page
- **THEN** the "Supplied by" section says that the in-memory loop supplies it and the core-only loop does not

### Requirement: An index lists every capability
`docs/capabilities/README.md` SHALL explain what a capability is, how a loop declares it, and how a library requires it or uses it optionally. It SHALL have a table with one row for each capability page: the capability's name linked to its page, a one-line purpose, and its operations and events. `README.md`, `docs/libraries.md` and `docs/contract.md` SHALL link to it.

#### Scenario: A page missing from the index
- **WHEN** `docs/capabilities/limits.md` exists and the index has no row for it
- **THEN** the capability page check fails and names the page

#### Scenario: A reader starts from the contract
- **WHEN** a reader reaches the relay section of `docs/contract.md`
- **THEN** it links to `docs/capabilities/relay.md`

### Requirement: Adding a capability includes its page
`CONTRIBUTING.md` SHALL state that a change which adds a capability adds its page and its index row, with a checked example, in the same change. The tasks of such a change SHALL include writing the page.

#### Scenario: A contributor reads how to add a capability
- **WHEN** a contributor reads `CONTRIBUTING.md` to add a capability
- **THEN** it says to add `docs/capabilities/<name>.md` with the fixed sections and a checked example, and a row in the index
