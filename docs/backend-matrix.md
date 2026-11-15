# Backend and conformance plan

## Initial implementation

The first reference backend is Linux epoll plus eventfd: level-triggered
read/write interest, generation-encoded registration keys, explicit
deregistration, monotonic one-shot timers, and cross-thread wakeup.

| Backend | Status |
|---|---|
| Linux epoll | Initial implementation |
| Linux io_uring | Not implemented |
| macOS / BSD kqueue | Not implemented |
| Windows IOCP | Not implemented |
| Windows RIO | Optional future optimization |

The public API must not expose backend-specific handles or require consumers to
know whether a backend is readiness- or completion-driven.

## Required conformance suite

Every backend must pass tests for registration/modification/deregistration,
readable/writable/error/reset/EOF/half-close notifications, partial I/O,
WouldBlock semantics, stale handles after slot reuse, timer deadline/cancel/race,
wake while blocked, wake coalescing, closing watched sockets, high churn,
descriptor reuse, bounded capacity, and level-triggered correctness.

A deterministic fake provider should run on every CI platform; native backends
must be tested on their actual operating systems. No backend is supported based
on successful compilation alone.
