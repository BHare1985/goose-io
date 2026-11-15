# Architecture and design boundaries

## The three layers

### 1. Shared contract

The contract is the only thing a framework or async client library must agree
on. It defines:

- `Link` and `Timer`, both slot-plus-generation and worker-affine;
- `Address`, `IoError`, and nonblocking operation results;
- `Interest` and bounded `WaitSet` values that a coroutine yields;
- `Completion` values returned by a provider's poll loop;
- socket lifecycle operations, timer cancellation, and thread wakeup.

The package uses static generic/UFCS dispatch. No dynamic provider vtable is
required, and no consumer imports another consumer.

### 2. Provider implementation

An implementation owns its OS handles, link table, readiness/completion
registrations, timer state, and native error translation. It may use epoll,
kqueue, IOCP, io_uring, or a framework's existing event loop.

The reference implementation is `EpollIo`. It gives a framework or library a
standalone Linux TCP provider. It is not the only valid implementation.

### 3. Framework and library consumers

A framework owns its coroutine scheduler and application protocol execution.
A client library owns its protocol state, pooling, retries and query/request
correlation. The reactor does not learn whether a `Link` belongs to HTTP,
Postgres, Redis, or a proxy.

A route coroutine can call a nested client coroutine. Its yielded `WaitSet`
propagates to the scheduler. The scheduler already knows the coroutine frame
that yielded; no application `owner` tag or per-library event dispatch is
needed.

## What is generic and what is not

| Concern | Shared contract/provider | Consumer-specific |
|---|---|---|
| Stable socket identity and stale-handle rejection | Yes | No |
| Listen, accept, dial, nonblocking read/write | Yes | No |
| Readiness interests, poll completions, timers, wake | Yes | No |
| Normalized transport errors | Yes | No |
| Coroutine frame storage/resumption policy | Scheduler/runtime | Framework/runtime |
| HTTP parsing, routing, middleware | No | HTTP framework |
| Postgres framing, SCRAM, query matching | No | Postgres driver |
| Pool sizing, reconnect/backoff, prepared statements | No | Client library |
| Proxy byte pump, backend selection, SNI routing | No | tcprouter |
| Buffer pools and per-connection write queues | No in v1 | Provider/consumer optimization |

## Readiness vs completion APIs

The public base standardizes operations and wait semantics, not the native OS
mechanism. In v1, stream operations are nonblocking:

- `try_read` writes into a caller-owned buffer and returns a partial byte count,
  `WouldBlock`, EOF, or another error.
- `try_write` returns the number of bytes accepted by the kernel. Partial
  writes are normal; the caller retains the remaining suffix.
- `WaitSet` represents the event(s) the coroutine is waiting for. A readiness
  completion resumes the coroutine, which retries the operation.

This is a deliberate choice for the first shared contract. It naturally maps
to epoll/kqueue and can be emulated by completion-oriented providers. It also
avoids imposing tcprouter's borrowed pooled-buffer lifetime on every backend.

A later optional extension may add provider-owned read slices or owned writes.
Those must have explicit leases and cancellation rules; they must not silently
change the base API.

## Why tcprouter is not copied wholesale

The tcprouter worker is a TCP proxy engine. It includes an epoll loop, a
connection table, route policy, SNI inspection, a pool of forwarding buffers,
backpressure, connect retry, half-close, lease deadlines, drain, and statistics.
Only its OS-facing event-loop and socket primitives belong in a general-purpose
provider.

`EpollIo` ports those low-level techniques: nonblocking sockets, packed epoll
event isolation, negative errno returns, generation-keyed event data, eventfd
wakeups, and monotonic timers. It intentionally does not carry proxy policy or
tcprouter's connection-forwarding state machine.

A tcprouter `Worker` can independently implement the same generic contract
using its existing highly optimized event loop. That is preferable to making
it replace proven proxy-specific machinery with the generic reference provider.

## Scheduling and wait sets

The scheduler owns the mapping from yielded `WaitSet` values to coroutine
frames. It aggregates registrations: if several frames wait for the same
`(Link, Interest)`, the scheduler installs one provider registration and keeps
its own waiter list. It removes the provider registration only when the last
waiter leaves. The provider does not need application or library owner tokens.

A wait set can combine, for example, `Readable(link)` and `Timer(timer)`. When
one completion wins, the scheduler resumes that frame and unregisters its
other interests. The losing timer can be cancelled; a late completion is
rejected by its generation.

A `Wake` completion is intentionally untagged. Another thread puts work in a
worker-owned mailbox/queue and calls `wake()`. The worker wakes and drains its
queue. The queue entry carries the actual work identity.

Goose coroutine support and the full scheduler are not implemented by this
repository. The types here define the seam they must use.

## Optimized native reactor path

The Linux backend also exposes an explicitly Linux-specific raw epoll path for
frameworks that already own their connection tables and dispatch loops:

- `goose_io_epoll_create_raw`
- `goose_io_epoll_ctl_raw`
- `goose_io_epoll_wait_raw`

It passes the native epoll event mask and opaque 64-bit user key through
unchanged. It does not normalize flags, allocate a per-event Link, or translate
keys through a generic registration table. The caller chooses level- or
edge-triggering and retains its existing generation validation and dispatch.

This is an optimization capability, not part of the portable I/O contract.
It exists so a tuned engine such as tcprouter can share the Linux epoll syscall
boundary without replacing its own pump, connection slots, buffer pool,
backpressure, ready queue, batching, or scheduler policy.

The standalone `EpollIo` remains the ergonomic reference provider. Its
normalized event API and its raw fast path serve different use cases; do not
route a high-throughput proxy through the generic event-normalization layer
when the raw path is the better fit.
