# Proposal

## Why

Goose has several event loops (tcprouter and skein, goose-http, goose-wing) and each needs its own Postgres, Redis and HTTP clients, because only one loop can own a thread and the loops disagree on how a library dials, sends and receives. A single contract between "the loop" and "a library on the loop" removes that: a client written once runs on every loop that provides the contract.

Version 1 of goose-io is that contract and nothing else. Event-loop implementations are examples that will live beside it in this repository and move to their own repositories before goose-io is made public. The first priority is a contract that is precisely defined, compiles, and is tested. The code in the repository today does not compile (`goose check` fails on `reactor/epoll.goose`) and defines a readiness-style contract that a completion-based loop cannot provide without extra copies.

This change replaces the unapplied change `define-io-contract`, which bundled the contract with moving tcprouter's engine into goose-io. That engine work becomes a later example-provider change.

## What Changes

- **BREAKING** Remove the existing `core/`, `reactor/`, `shim/`, `tests/lit/`, `tests/native/` and the build sidecar. Nothing released depends on them.
- Define the contract as pure Goose: fixed-size shared types (`Link`, `Listener`, `Event`, `SendStatus`, `CloseReason`, `ListenError`) and the operations and events every provider must supply. The package contains no C and no `extern`, so a library that imports it links nothing.
- The contract is the event-driven shape tcprouter and skein already run on (events in, calls out; received bytes lent for one event; sends taken whole or refused). Compared with the superseded plan it adds a host side (`serve`, `stop` with a grace period), `listener_port`, a rule that the user value set after `dial` is carried even by an immediate failure, and a stated contract version.
- Ship an in-memory provider (no sockets, virtual clock) so libraries can be tested without a network and so the contract has one working implementation from day one.
- Ship a provider-neutral conformance suite, written only against the contract, that any provider in any repository can run. Each check is shown to fail against a deliberately broken provider.
- Ship two small example libraries (a server and a pooled, pipelining client) and one program that runs both on one loop, as proof that libraries compose without naming each other or a provider.
- Record, for each planned example provider (uSockets, tcprouter's engine, io_uring), how every operation and event maps onto it, checked against that provider's source, with every unverified point listed.
- Rewrite `README.md` and `docs/` as the contract reference, a guide for library authors and a guide for provider authors.

Out of scope, each a later change: the uSockets example provider, the tcprouter-engine example provider (with its performance-parity gates and extension seam), an io_uring example provider, and the tcprouter refactor itself (a separate project). Also out of scope: coroutines, TLS, DNS, UDP, Unix sockets, files, and cross-thread messaging.

## Capabilities

### New Capabilities
- `io-contract`: the provider-neutral contract between an event loop and the libraries and application that run on it: types, operations, events, ordering rules, the host side, the version, and the rule that the contract package is pure Goose.
- `provider-conformance`: how a provider is shown to satisfy the contract and how a library is tested against it: the conformance suite, the in-memory provider, the example libraries, and the recorded mapping for each candidate provider.

### Modified Capabilities

None. No specifications have been archived in this repository.

## Impact

- **goose-io:** every source file is replaced. The package becomes pure Goose with no build sidecar. `README.md`, `docs/`, `Justfile` and `CONTRIBUTING.md` are rewritten to match.
- **Planning:** the change `define-io-contract` is superseded and must not be applied. Its engine-import, extension-seam and performance-gate material is the starting point for the later tcprouter-engine example change.
- **tcprouter, skein, goose-postgres, goose-http, goose-wing, c_proxy:** not modified. tcprouter's `integrate/goose-io` branch pins a goose-io commit that stays in history; that branch is superseded.
- **Dependencies:** none added. The Goose toolchain v2026.4 is the only requirement; tests run with `goose run` because nothing links C.
- **Risk carried forward:** until a socket-backed provider passes the suite, the contract has been exercised only by the in-memory provider. It is published as version 0, and the first real provider is allowed to amend it.
