# Spec Delta

## MODIFIED Requirements

### Requirement: A finished loop does nothing
On a finished loop every operation SHALL return without blocking or delivering an event. `dial` SHALL return the invalid link, issuing no link and starting no connection; this is an exception to *Dialling never blocks and always ends in one event*, as is a dial that a layer beneath the library refuses (*A layer may refuse a dial*). `send` and `send2` SHALL return `Closed`, `send_room` 0, and `listen` SHALL fail with kind `Other`. Every other operation SHALL have no effect, and a second `serve` SHALL return at once.

#### Scenario: Operations after serve returns
- **WHEN** `serve` has returned and the application calls `send` on a link it held, `listen`, `dial`, `close`, `pause_reading`, `tick_by`, `draining` and `now_ms`
- **THEN** `send` returns `Closed`, `listen` returns an error of kind `Other`, `dial` returns a link for which `is_valid` is false, `draining` is true, `now_ms` is no earlier than before, and no call blocks

#### Scenario: Serve a second time
- **WHEN** an application calls `serve` on a finished loop
- **THEN** `serve` returns at once and its handler is never called

## ADDED Requirements

### Requirement: A layer may refuse a dial
A layer between a library and the event loop MAY refuse a `dial`, and SHALL then return the invalid link, issue no link, start no connection and deliver no event for it. A library SHALL check `is_valid` on the link `dial` returns.

#### Scenario: A refused dial
- **WHEN** a view refuses a dial because of a limit
- **THEN** `dial` returns a link for which `is_valid` is false and no event follows
