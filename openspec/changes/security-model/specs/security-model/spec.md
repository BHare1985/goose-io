# Spec Delta

## Purpose

A written threat model for goose-io: who is trusted, how each operation is classified, which threats are answered and by what, and a check that keeps the list complete.

## ADDED Requirements

### Requirement: The model states what it is and is not
`docs/security.md` SHALL state that goose-io is a contract between cooperating code in one process and not a sandbox, and SHALL list what it does not protect: process isolation, confidentiality on the wire, and the supply chain of its dependencies.

#### Scenario: Reading the model
- **WHEN** a reader opens `docs/security.md`
- **THEN** it says that code in the process can do what the process can, and what is out of scope

### Requirement: Every operation has a class
`docs/security.md` SHALL list every operation of the contract with its class, library or application, and the effect a hostile caller of that operation could have.

#### Scenario: An operation without a row
- **WHEN** an operation of the contract has no row in the table
- **THEN** `tests/checks/security.sh` fails

### Requirement: Every threat names its answer
Each threat in `docs/security.md` SHALL name the change or capability that answers it, or say that it is out of scope and why.

#### Scenario: A threat without an answer
- **WHEN** a threat row names neither an answer nor "out of scope"
- **THEN** `tests/checks/security.sh` fails

### Requirement: New operations state their security impact
A change that adds an operation or an event SHALL state its class and its security impact in its design, and `CONTRIBUTING.md` SHALL say so.

#### Scenario: A contributor adds an operation
- **WHEN** a contributor reads `CONTRIBUTING.md` before adding an operation
- **THEN** it tells them to classify it and to state what a hostile caller could do with it

### Requirement: The model is linked from where readers start
`README.md` and `docs/libraries.md` SHALL link to `docs/security.md`.

#### Scenario: A library author looks for the rules
- **WHEN** a library author reads `docs/libraries.md`
- **THEN** they find a link to the security model
