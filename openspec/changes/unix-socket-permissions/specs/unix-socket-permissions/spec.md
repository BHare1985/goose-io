# Spec Delta

## Purpose

What an event loop that supplies the unix group does to the socket file: it does not take an existing path, it creates the file owner-only, and it removes what it created.

## ADDED Requirements

### Requirement: An existing path is never replaced
`listen` on a unix path that already exists SHALL fail with kind `AddressInUse`, and SHALL NOT remove, replace or change the existing file.

#### Scenario: Listening on a taken path
- **WHEN** a library listens on a unix path that another listener or file holds
- **THEN** `listen` fails with kind `AddressInUse` and the first listener keeps accepting

### Requirement: A socket file is owner-only by default
A socket file that an event loop creates SHALL be accessible by its owner only, unless the application has given the loop another mode through the loop's own configuration.

#### Scenario: A default socket
- **WHEN** a loop creates a socket file and the application gave no mode
- **THEN** the file is accessible by its owner only

### Requirement: The loop removes the file it created
An event loop SHALL remove a socket file it created when its listener is stopped and when the loop finishes, and SHALL NOT remove a file it did not create.

#### Scenario: The path after a stop
- **WHEN** a listener on a unix path is stopped with `stop_listening`
- **THEN** the path is free and a `listen` on it succeeds

#### Scenario: The path after the loop finishes
- **WHEN** `serve` returns with a unix listener open
- **THEN** the path is free

### Requirement: Each mapping document states the file handling
Each document in `docs/event-loops/` SHALL have a "Unix" section saying how the loop meets these requirements, or that it supplies no unix group.

#### Scenario: A document without the section
- **WHEN** `tests/checks/event_loops.sh` finds a mapping document with no "Unix" section
- **THEN** the check fails
