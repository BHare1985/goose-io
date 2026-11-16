# Spec Delta

## Purpose

Defines the provider-neutral contract between an event loop (a provider) and the libraries and application that run on it, so an async client or server library written once runs on any conforming provider, whether that provider is built on readiness (epoll, kqueue) or completion (io_uring, IOCP).

## ADDED Requirements

### Requirement: A refused send is always resolved
After a `send` or `send2` on a link has returned `Full`, the link SHALL receive one `Writable` or its `Closed`; it SHALL NOT stay open and silent for ever. A `Writable` SHALL NOT be delivered for a link whose sending has ended by `shutdown_write`, `close` or `reset`, including one the provider had already queued. Which of `Writable` or `Closed` a provider gives when the peer goes away is the provider's choice.

#### Scenario: The write side is shut while a Writable is owed
- **WHEN** a library has been refused with `Full`, the peer reads enough that a `Writable` is owed, and a handler calls `shutdown_write` on the link before that `Writable` is delivered
- **THEN** no `Writable` is delivered for the link, `send` returns `Closed`, and the link still delivers `Data` and `PeerEof` from the peer

#### Scenario: The write side is shut after a refusal
- **WHEN** a library has been refused with `Full` and then calls `shutdown_write` before the peer reads anything
- **THEN** no `Writable` is delivered for the link, even when the peer later reads everything

#### Scenario: The peer closes while a send is refused
- **WHEN** a library has opted in with `set_keep_open_on_eof(link, true)`, has been refused with `Full` because the peer never read, and the peer then closes its end
- **THEN** the link receives one `Writable` or its `Closed` after the peer's close, and does not stay open with neither

#### Scenario: The retry after the peer is gone
- **WHEN** the link of the previous scenario received `Writable` and the library sends again
- **THEN** `send` returns `Sent` or `Closed`, never `Full`, and the link then ends with `Closed`
