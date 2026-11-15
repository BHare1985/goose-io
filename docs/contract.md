# Shared I/O contract

This document defines the v1 provider contract declared in `core/io/types.goose` and `core/io/contract.goose`.

## Provider methods

| Method | Semantics |
|---|---|
| `listen(address, options)` | Create a nonblocking TCP listener and return a `Link` |
| `accept(listener)` | Accept one connection; return `WouldBlock` when none is queued |
| `dial(address)` | Start a nonblocking connect and return its `Link` |
| `try_read(link, dst)` | Attempt one read into caller-owned memory |
| `try_write(link, src)` | Attempt one write; partial progress is valid |
| `pause_reading(link, paused)` | Suppress/restore read readiness for backpressure |
| `shutdown_write(link)` | Half-close the local sending direction |
| `close(link)` | Close normally and invalidate the handle |
| `reset(link)` | Abort the TCP connection (RST) and invalidate the handle |
| `watch(interest)` / `unwatch(interest)` | Arm/disarm a scheduler readiness interest |
| `after(deadline_ns)` | Create a one-shot absolute monotonic timer |
| `cancel_timer(timer)` | Cancel a timer; false means stale or already completed |
| `poll(timeout_ms, completions)` | Wait for native events; return count or -1 and set `last_error` |
| `wake()` | Interrupt a blocked poll from another thread |

Addresses are numeric IPv4 or IPv6. DNS is separate: `dial` never performs a blocking name lookup.

## Handles and ownership

`Link` and `Timer` are `(slot, generation)` handles and are worker-affine. A provider increments a slot's generation when it is retired. Every operation checks the generation before accessing the descriptor. Raw file descriptors and native event keys are private backend details.

## Nonblocking reads and writes

`try_read` and `try_write` never wait for the OS.

- A positive result is the number of bytes transferred.
- `WouldBlock` means no progress can be made now; wait for Readable or Writable and retry.
- Read EOF is reported as `IoErrorKind.Eof`.
- Writes may be partial. The caller retains and retries the unwritten suffix.
- Providers do not retain caller memory after either operation returns.

A generic `read_exact` or `write_all` coroutine can be built over these primitives and a `WaitSet`.

## Wait and completion semantics

A coroutine yields a bounded `WaitSet`. The scheduler records the coroutine frame against each interest. The provider reports resource-oriented completions: accept-ready, connected, readable, writable, peer EOF, closed/error, timer, or wake.

The scheduler resumes the frame associated with the winning completion. For a multi-interest wait, it removes the losing registrations and cancels losing timers. The provider never receives an application/library owner token.

The scheduler coalesces duplicate waits for the same resource/interest: call `watch` for the first waiter and `unwatch` after the last waiter leaves.

### Listener and connect

`listen` creates a listener. `Interest.Accept` arms it. `accept` retrieves one connection and may return `WouldBlock` if another consumer drained the backlog first.

`dial` returns a link when the nonblocking connect is initiated. The provider monitors writability and resolves `SO_ERROR`. Success produces one `Completion.Connected`; failure produces `Completion.Closed` with a normalized error. The failed link remains allocated only so the caller can close it; read/write are rejected.

### EOF and close

Peer EOF is directional and does not prohibit local writes. `shutdown_write` ends the local sending direction. `close` closes normally; `reset` sets TCP linger to zero and aborts the connection. Both invalidate the link. A terminal `Completion.Closed` reports an error; the caller closes the link.

### Timers and wakeups

Timers use absolute `CLOCK_MONOTONIC` nanosecond deadlines in the Linux backend. Expiry is delivered on the first poll at or after the deadline; this is not hard real-time. Cancellation succeeds only while the timer remains live. Generation checks reject stale timer handles.

`wake()` interrupts poll but carries no message. Cross-thread work belongs in a worker-owned queue/mailbox, which the worker drains after receiving `Completion.Wake`.

## Error normalization

Consumers branch on `IoErrorKind`, not platform strings. `IoError.code` retains the native numeric error where available. Linux normalizes would-block, refused, timeout, reset, unreachable, resource exhaustion, address conflicts, permission denied, closed descriptors, unsupported address families, and invalid arguments. Other errors are `System` with the original errno.

## Scope boundaries

The v1 contract does not define DNS, UDP, TLS, files, signals, HTTP, database protocols, buffer pools, proxy routing, health policy, or a global work-stealing scheduler. Those belong above the common stream operations or in separately versioned capabilities.
