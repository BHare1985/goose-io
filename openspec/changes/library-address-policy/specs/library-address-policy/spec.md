# Spec Delta

## Purpose

An allow-list for the addresses a library may dial or listen on, enforced by its view before a call reaches the event loop.

## ADDED Requirements

### Requirement: A policy is explicit and per library
A library SHALL be added to the registry with an address policy. There SHALL be no default policy; the application SHALL pass rules, or `allow_all()`.

#### Scenario: A library is added without a policy
- **WHEN** an application adds a library to the registry and passes no policy
- **THEN** the build fails

### Requirement: An address that matches no rule is refused
A view SHALL pass a `dial` or `listen` to the loop only if its address matches an allow rule for that operation. Otherwise the view SHALL refuse it and the loop SHALL not see the call.

#### Scenario: A library dials a loopback port it was not given
- **WHEN** a library whose policy allows only `203.0.113.0/24:443` dials `127.0.0.1:2375`
- **THEN** the dial is refused and the loop is not called

### Requirement: A refused dial returns the invalid link
A refused `dial` SHALL return the invalid link, issue no link and start no connection.

#### Scenario: A refused dial
- **WHEN** a view refuses a dial
- **THEN** `dial` returns a link for which `is_valid` is false and no event follows

### Requirement: A refused listen fails with Denied
A refused `listen` SHALL fail with a `ListenError` of kind `Denied`, and no listener SHALL be made.

#### Scenario: A refused listen
- **WHEN** a library whose policy allows listening only on `127.0.0.1:8000-8100` listens on `0.0.0.0:22`
- **THEN** `listen` fails with kind `Denied`

### Requirement: Rules cover TCP ranges and unix prefixes
A TCP rule SHALL name an IPv4 or IPv6 range in CIDR form and an inclusive port range. A unix rule SHALL name a path prefix, and SHALL match a path only on whole path components.

#### Scenario: A prefix is not a substring
- **WHEN** a library whose policy allows the unix prefix `/run/app` dials `/run/application.sock`
- **THEN** the dial is refused

### Requirement: Paths with parent components are refused
A view SHALL refuse a unix address containing a `..` component before matching any rule.

#### Scenario: An escape by name
- **WHEN** a library whose policy allows `/run/app` dials `/run/app/../docker.sock`
- **THEN** the dial is refused

### Requirement: What a rule cannot do is stated
The documents SHALL say that a rule is checked on the address as written, so a symbolic link beneath an allowed path is followed by the operating system, and that the policy is not a firewall.

#### Scenario: Reading the documents
- **WHEN** a reader looks for the limits of a path rule
- **THEN** `docs/libraries.md` states the symbolic link case
