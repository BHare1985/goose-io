# goose-io

A small, framework-independent I/O contract and reference reactor for Goose.

`goose-io` is intended to be the common I/O boundary for HTTP frameworks,
reverse proxies, database drivers, Redis clients, and other asynchronous
libraries. A library depends on the contract, not on Skein, tcprouter, or any
other framework.

The package has two deliberately separate responsibilities:

1. **The contract** defines stable handles, socket operations, readiness,
   timers, wakeups, and the event types used by coroutine schedulers.
2. **The reference reactor** implements the reactor side of that contract.
   Frameworks can use it directly, or implement the same contract with an
   existing reactor such as tcprouter.

There is no service-integration layer, framework adapter, driver-specific
Postgres module, or application-level event-owner switch.

## Current state

This is the stripped-down first cut, not yet a production-ready multi-platform
reactor.

| Backend | Status |
|---|---|
| Linux epoll | Initial implementation included |
| Linux io_uring | Not implemented yet |
| macOS / BSD kqueue | Not implemented yet |
| Windows IOCP | Not implemented yet |
| Windows RIO | Not planned as the default; optional optimization only |

The public contract is designed so these backends can be added without changing
consuming libraries. The epoll backend and test suite have **not** been built or
run in this environment because the Goose compiler is unavailable here.

## Intended usage

The public API is compile-time/UFCS based. Implementations provide the required
methods in their own namespace; generic library code calls the contract wrappers.
No runtime vtable or heap-allocated callback is required.

A coroutine-aware framework should expose the same `Io` provider to its route
handlers that the async client library uses:

```goose
// Illustrative target syntax; coroutine support is still a Goose runtime
// prerequisite and this example is not a compiler-verified program.
coro fn feed(req: skein::Request&) resume goose_io::IoEvent {
    let io = req.io();
    let rows = pg::query(io, DB, "SELECT * FROM posts", 20);
    req.reply(200, rows);
}
```

The Postgres library uses only the common `Io` contract. Skein does not need to
know about Postgres, and Postgres does not need to know about Skein.

## Package layout

- `core/io/types.goose` — shared handles, errors, readiness flags, waits, events.
- `core/io/contract.goose` — generic UFCS entry points for socket and reactor
  operations.
- `reactor/epoll.goose` — generation-checked reference reactor and timers.
- `shim/epoll.c` — small Linux epoll/eventfd shim.
- `tests/lit/` — focused reactor tests, intended to become the backend
  conformance suite as additional backends land.
- `docs/contract.md` — behavioral requirements and coroutine integration.
- `docs/backend-matrix.md` — backend plan and conformance requirements.

## Build integration

`goose-io.build` lists the native shim for Linux. The package currently contains
no platform-specific shim for macOS or Windows, so those targets should not be
reported as supported until their implementations and tests are added.

## Design constraints

- Resource handles are opaque `(slot, generation)` values, never raw file
  descriptors exposed as stable identities.
- Readiness events identify resources, not application owners. The coroutine
  scheduler associates a yielded `Wait` value with its coroutine frame.
- Timers use absolute monotonic nanosecond deadlines.
- A readiness event is a prompt to retry a nonblocking operation; it does not
  promise that an entire read or write can complete.
- Partial writes are normal. `write_all` belongs in a reusable coroutine helper
  built over `try_write` and `Wait.Writable`.
- Closing or reusing a resource invalidates old handles through generation
  checks.
- The reactor owns polling, registrations, timers, and wakeup. Protocol parsing,
  pooling, SQL, HTTP routing, health policy, and failover do not belong here.

## License

Apache-2.0. See `LICENSE`.

The native Linux shim can be checked independently of the Goose compiler with
`just native-smoke` (or by compiling `tests/native/epoll_smoke.c` together with
`shim/epoll.c`). This verifies the native registration, readiness, modification,
wakeup, monotonic-clock, and cleanup paths; it does not validate the Goose
wrapper or coroutine scheduler integration.
