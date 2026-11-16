# Spec Delta

## Purpose

Defines how a provider is shown to satisfy the I/O contract and how a library is tested against it: one conformance suite written only against the contract, an in-memory provider for tests without sockets, example libraries that prove composition, and a recorded mapping for each candidate provider.

## ADDED Requirements

### Requirement: The in-memory loop always makes progress
No configuration of the in-memory provider SHALL make `serve` run without its clock moving towards the time limit. A `tick_ms` or `passes_per_ms` below 1 SHALL be treated as 1. A test that never calls `stop` SHALL therefore end at the time limit, whatever the configuration.

#### Scenario: A tick period of zero
- **WHEN** a test sets `tick_ms` to 0, runs a loop that counts `Tick` events, and stops it from the handler at 50 ms of the loop's clock
- **THEN** `serve` returns, the clock reads at least 50, and the loop delivered no more than one `Tick` per millisecond of that clock

#### Scenario: A negative tick period
- **WHEN** a test sets `tick_ms` to -5 and runs a loop that never calls `stop`, with `exit_on_time_limit` off
- **THEN** `serve` returns once the time limit has passed on the loop's clock and `hit_time_limit` is true

#### Scenario: A pass rate of zero
- **WHEN** a test sets `passes_per_ms` to 0 and two joined links exchange bytes until a handler stops the loop
- **THEN** the loop ends normally

### Requirement: Stopping lets scripted peers finish reading
After `stop`, `serve` SHALL NOT return while a scripted peer's link holds bytes the library has sent that the peer is still going to read, or an end of stream the peer has not yet seen. A peer told to stop reading, and a peer whose later steps are not yet due, SHALL NOT delay `serve`.

#### Scenario: Send, close, stop
- **WHEN** a library sends a reply to a scripted peer, calls `close`, and calls `stop(0)` from the handler of that link's `Closed`
- **THEN** after `serve` returns the test reads the whole reply with `peer_received`, and `peer_saw_eof` is true

#### Scenario: Shutdown instead of close
- **WHEN** a library sends a reply to a scripted peer, calls `shutdown_write`, and calls `stop(0)` from the same handler
- **THEN** after `serve` returns the peer has received the whole reply and `peer_saw_eof` is true, and the library's link still received `Closed` with reason `Shutdown`

#### Scenario: A peer that stopped reading does not hold the loop
- **WHEN** a scripted peer has been told to stop reading, the library has sent it bytes and called `close`, and the library calls `stop(0)`
- **THEN** `serve` returns without waiting for the peer, and `peer_received` holds only what the peer read before it stopped

#### Scenario: A peer with a distant step does not hold the loop
- **WHEN** a scripted peer has a step due ten seconds later, the library has finished with its link, and the library calls `stop(0)`
- **THEN** `serve` returns before that step is due

### Requirement: Listener addresses do not overlap
In the in-memory provider, `listen` SHALL fail with `AddressInUse` when an active listener or a held address has the same address family and port and either address is the wildcard or the two are equal. A dial SHALL therefore match at most one listener. A stopped listener SHALL NOT conflict, and IPv4 and IPv6 are separate families.

#### Scenario: Wildcard then specific
- **WHEN** a library listens on `0.0.0.0:8080` and then on `127.0.0.1:8080`
- **THEN** the second `listen` returns `AddressInUse` and a dial to `127.0.0.1:8080` opens a link carrying the first listener's tag

#### Scenario: Specific then wildcard
- **WHEN** a library listens on `127.0.0.1:8080` and then on `0.0.0.0:8080`
- **THEN** the second `listen` returns `AddressInUse`

#### Scenario: A held wildcard
- **WHEN** a test holds `0.0.0.0:8080` and a library listens on `127.0.0.1:8080`
- **THEN** `listen` returns `AddressInUse`

#### Scenario: Different ports, families and stopped listeners
- **WHEN** a library listens on `0.0.0.0:8080`, then on `127.0.0.1:8081` and `[::1]:8080`, and stops the first listener and listens on `127.0.0.1:8080`
- **THEN** every one of those `listen` calls succeeds

### Requirement: System-chosen ports are free ports
In the in-memory provider, `listen` on port zero SHALL choose a port from 49152 to 65535 that no active listener or held address uses, SHALL return a non-zero `listener_port`, and SHALL fail with `NoResources` only when every port in that range is in use. Accepted connections SHALL report a remote port in the same range.

#### Scenario: The next port is taken
- **WHEN** a library listens explicitly on `127.0.0.1:49152` and then listens on `127.0.0.1:0`
- **THEN** the second `listen` succeeds and its `listener_port` is in the range and is not 49152

#### Scenario: Ports do not run out of range
- **WHEN** a loop accepts more than 16384 connections and a library then listens on port zero
- **THEN** `listener_port` is non-zero and at least 49152, and `peer_address` of the last accepted link names a port in the range

#### Scenario: Every port is in use
- **WHEN** every port from 49152 to 65535 on one address is held or listened on and a library listens on port zero there
- **THEN** `listen` returns `NoResources`

### Requirement: The in-memory provider states its limits
The in-memory provider SHALL document, and its tests SHALL pin, the bounds a library can observe. `max_links` SHALL count link ends on the loop, so a pair joined inside the loop uses two and a connection to a scripted peer uses one. The address grammar SHALL be `ip:port` for IPv4 and `[ip]:port` for IPv6 with hexadecimal groups; IPv4-embedded IPv6 text SHALL be `BadAddress`.

#### Scenario: A joined pair uses two links
- **WHEN** a loop is configured with `max_links` of 2, one library listens, another dials it, and a third dial is made once both ends are open
- **THEN** the first dial opens on both ends and the third fails with `ConnectFailed`, kind `NoResources`

#### Scenario: A scripted peer's end is not counted
- **WHEN** a loop is configured with `max_links` of 1 and a library dials an address where a scripted peer waits
- **THEN** the dial opens

#### Scenario: IPv4-embedded IPv6 text
- **WHEN** a library dials `[::ffff:192.0.2.1]:80` or listens on `[::ffff:192.0.2.1]:80`
- **THEN** the dial ends with `ConnectFailed`, kind `BadAddress`, and the listen returns `BadAddress`
