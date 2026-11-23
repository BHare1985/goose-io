# Spec Delta

## Purpose

Per-library limits on the links, listeners and wake-ups that a view lets a library use, so that one library cannot use up what the libraries on one event loop share.

## ADDED Requirements

### Requirement: Limits are explicit and per library
A library SHALL be added to the registry with limits: a maximum of open links, a maximum of listeners and a minimum interval between the wake-ups it asks for. There SHALL be no default; the application SHALL pass limits, and MAY pass limits that are unbounded.

#### Scenario: A library is added without limits
- **WHEN** an application adds a library to the registry and passes no limits
- **THEN** the build fails

### Requirement: A link limit counts every link of the library
The links counted against a library's limit SHALL be the links it dialled and the links its listeners accepted, until their `Closed` has been handled. A `dial` that would exceed the limit SHALL return the invalid link, issue no link and start no connection.

#### Scenario: A library dials without end
- **WHEN** a library with a limit of 8 dials 100 times without closing anything
- **THEN** the first 8 dials return valid links, the others return the invalid link, and another library's dial still succeeds

### Requirement: An accepted link over the limit never reaches the library
An accepted link that would take its listener's library over its link limit SHALL be closed by the registry before the library is offered any event for it, and SHALL be counted as refused.

#### Scenario: A flood at one listener
- **WHEN** a peer opens 100 connections to a listener whose library has a limit of 8
- **THEN** the library sees 8 `Opened` events, the other 92 links are closed, and the refused count is 92

### Requirement: A listener limit
A `listen` that would exceed a library's listener limit SHALL fail with a `ListenError` of kind `NoResources`, and no listener SHALL be made.

#### Scenario: Too many listeners
- **WHEN** a library with a limit of 2 listeners calls `listen` three times
- **THEN** the third call fails with kind `NoResources` and the first two listeners keep accepting

### Requirement: Wake-ups are rate limited
A view SHALL pass `tick_by(at_ms)` to the loop as no earlier than the library's minimum interval after the last wake-up the library asked for, and SHALL count each request it moved.

#### Scenario: A library that asks for a Tick at once, every Tick
- **WHEN** a library calls `tick_by(now_ms())` in every `Tick` handler with a minimum interval of 10 ms
- **THEN** the loop wakes it no more than once in 10 ms, and another library's timers are served on time

### Requirement: The application can read the counters
The registry SHALL keep for each library the links open, the dials, listens and links refused, and the wake-ups moved, and SHALL offer them to the application.

#### Scenario: Counting refusals
- **WHEN** a library has had 92 links and 3 dials refused
- **THEN** the application reads 92 and 3 for that library
