# Spec Delta

## Purpose

Describes the reference Linux epoll provider of the I/O contract: a share-nothing worker per thread, derived from tcprouter's engine, that libraries can run on directly and that a specialised engine such as tcprouter can extend without losing behaviour or performance.

## ADDED Requirements

### Requirement: The engine provides the I/O contract
The epoll engine SHALL implement every operation and event of the `io-contract` capability and SHALL pass the provider conformance suite.

#### Scenario: Conformance on Linux
- **WHEN** the conformance suite is run against the epoll engine on Linux
- **THEN** every conformance check passes

### Requirement: One share-nothing worker per thread
Each worker SHALL own its event loop, links, buffers and tables and SHALL share no memory with other workers. Several workers SHALL be able to listen on the same address, with the kernel distributing new connections among them. Starting a worker SHALL report failure with a message naming the address and the operating system's error; it SHALL NOT abort the process.

#### Scenario: Several workers share a port
- **WHEN** four workers each listen on the same address and four hundred connections arrive
- **THEN** every connection is accepted by exactly one worker and every worker's count of accepted connections is at most four hundred, summing to four hundred

#### Scenario: A port held by another process is an error
- **WHEN** workers are started for an address that a different process is already listening on
- **THEN** start-up fails with a message naming the address, and the port is not silently shared with that process

### Requirement: Peers and the kernel cannot crash a worker
The engine SHALL NOT abort or exit because of anything a peer sends or does, or because of an event from the kernel that names an unknown slot, an unknown kind or an outdated generation. Such events SHALL be counted in the worker's statistics and otherwise ignored.

#### Scenario: An event for a closed link
- **WHEN** the kernel reports an event for a link that has since closed and whose slot has been reused
- **THEN** the new link is unaffected and the stale-event counter increases by one

#### Scenario: Hostile peers
- **WHEN** peers connect and reset, send partial data and vanish, or half-close at arbitrary points, thousands of times
- **THEN** the worker keeps serving other links and every affected link ends with exactly one `Closed`

### Requirement: Resource limits are configured and enforced without spinning
The engine SHALL accept limits for links per worker, read buffer size, buffers per worker, and connect, idle and half-close timeouts. When the process runs out of descriptors or memory while accepting, the engine SHALL count the failure and rest that listener briefly; it SHALL NOT busy-loop, and pending connections SHALL be accepted once resources return.

#### Scenario: Descriptor exhaustion while accepting
- **WHEN** the descriptor limit is reached while connections keep arriving
- **THEN** the worker's CPU use stays far below one full core, the accept-failure counter increases, and waiting connections are accepted after descriptors are freed

#### Scenario: The link limit is reached
- **WHEN** a dial would exceed the configured links per worker
- **THEN** that link receives one `Closed` with reason `ConnectFailed` and existing links are unaffected

### Requirement: Idle links hold no buffer
A link with no bytes in flight SHALL hold no read or send buffer; buffers SHALL come from a per-worker pool that is created lazily and never moves while in use. When the pool is empty, reads and refused sends SHALL wait in arrival order for a buffer to return, and the wait SHALL be counted.

#### Scenario: Memory per idle link
- **WHEN** ten thousand links are open and idle on one worker
- **THEN** resident memory has grown by no more than 512 bytes per link over the idle worker

#### Scenario: Pool exhaustion delays but does not lose data
- **WHEN** stalled links hold every buffer of a small pool and other links have data to read
- **THEN** the other links wait, the buffer-wait counter increases, and their data is delivered intact once buffers return

### Requirement: Timeouts are enforced within one sweep period
The engine SHALL close a link that has moved no bytes in either direction for the idle timeout with reason `IdleTimeout`, a half-closed link that outlives the half-close timeout with reason `HalfCloseTimeout`, and a dial that outlives its connect timeout with reason `ConnectFailed`. Idle and half-close closes SHALL occur no earlier than the limit and no later than the limit plus 250 ms.

#### Scenario: Idle timeout
- **WHEN** the idle timeout is one second and a link carries no bytes
- **THEN** the link is closed with reason `IdleTimeout` between 1.0 and 1.25 seconds after its last byte

#### Scenario: Activity resets the idle timer
- **WHEN** bytes move on a link in either direction, including bytes the library sends
- **THEN** the idle period is measured from that moment

### Requirement: Drain
A drain request SHALL reach every worker of the process exactly once and SHALL be handled before the network events of the same pass. On drain a worker SHALL stop listening at once, let open links finish, close links still open at the deadline with reason `Shutdown`, deliver their `Closed` events, and then return from its loop. The engine SHALL provide a helper that waits for a termination signal and then drains all workers.

#### Scenario: Drain with nothing open
- **WHEN** a drain is requested while no links are open
- **THEN** every worker stops listening and returns from its loop promptly

#### Scenario: Drain with a stuck link
- **WHEN** a drain with a two-second deadline is requested while one link stays open
- **THEN** new connections are refused at once, the link receives `Closed` with reason `Shutdown` at the deadline, and the worker then returns

### Requirement: Statistics
Each worker SHALL keep counters for accepted, open and closed links by reason, bytes in and out, connect failures, buffers in use, buffer waits, stale and invalid events, and accept failures, readable as a snapshot on the worker's own thread. A request to gather statistics SHALL return the sum over all workers.

#### Scenario: Counters are exact across workers
- **WHEN** a known number of connections is opened and closed across four workers and statistics are gathered
- **THEN** the summed accepted and closed counts equal the number of connections

### Requirement: An extension seam for specialised engines
The engine SHALL let a program supply an extension, resolved at compile time, that can own connection states the engine does not interpret, register additional sockets with the worker's event loop and receive their raw events, borrow and return pool buffers, queue a link for further work after the current batch, decide what happens to a newly accepted socket, refuse a send or flush, observe a link's close, and receive periodic sweeps and control messages addressed to it.

#### Scenario: An extension joins two sockets
- **WHEN** a test extension takes an accepted socket, connects a second socket, and copies bytes between them using raw events, pool buffers and the ready queue
- **THEN** bytes flow in both directions with backpressure, both sockets are closed when either side ends, and no contract event is delivered for that connection

#### Scenario: An extension refuses a send
- **WHEN** an extension reports that a link's tag is no longer allowed and a library then sends on that link
- **THEN** no bytes are transmitted and the link is closed with a provider-specific reason

### Requirement: The extension seam is free when unused
A worker run without an extension SHALL execute no extension code on any path. Supplying an extension whose hooks do nothing SHALL NOT change the system calls made per request.

#### Scenario: System calls with and without an empty extension
- **WHEN** the same request workload is traced on a worker with no extension and on a worker with an extension whose hooks are empty
- **THEN** the number of each system call per request is identical

### Requirement: Behaviour matches tcprouter's handler mode
For links handled by a library, the engine SHALL behave as tcprouter's handler mode does at the commit this change is derived from: the tcprouter tests that cover handler connections, dialled connections, half-close, pass-end, send queues, backpressure, generations, timeouts and drain SHALL pass against the engine once ported to the contract's names.

#### Scenario: Ported handler tests
- **WHEN** tcprouter's handler, dial, half-close, pass-end, queue, backpressure, generation, timeout and drain tests are run against the engine
- **THEN** every check passes, or a difference is recorded in the design with its cause before the change is accepted

### Requirement: Performance is no worse than tcprouter on the same workload
On the same host and with the same method, a keep-alive HTTP server built on the engine SHALL make the same number of each system call per request as the equivalent server built on tcprouter at the baseline commit, and its throughput, 99th-percentile latency and CPU per request SHALL be no worse than the baseline beyond the baseline's own run-to-run spread.

#### Scenario: System calls per request
- **WHEN** the keep-alive HTTP workload is traced for both servers
- **THEN** the counts of `recv`, `send`, `epoll_wait`, `epoll_ctl`, `accept` and `close` per request are equal

#### Scenario: Throughput and latency
- **WHEN** both servers are measured over alternating rounds on an otherwise idle host
- **THEN** the engine's median throughput, 99th-percentile latency and CPU per request each fall within, or better than, the range of the baseline's own repeated runs

#### Scenario: A forwarding extension holds tcprouter's forwarding numbers
- **WHEN** a test extension carrying tcprouter's forward pump is measured against tcprouter's own forwarding server on small, 16 KiB and 64 KiB keep-alive workloads
- **THEN** system calls per request are equal and median throughput, 99th-percentile latency and CPU per request fall within, or better than, the range of the baseline's own repeated runs

#### Scenario: A regression blocks acceptance
- **WHEN** any of these measurements is worse than the baseline's range
- **THEN** the change is not accepted until the cause is found and removed
