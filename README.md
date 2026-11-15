# goose-io

**One portable asynchronous I/O contract for Goose, plus a reusable Linux epoll implementation.**

`goose-io` is a small infrastructure package for Goose frameworks and libraries. Its purpose is to let an HTTP framework, a TCP server, a database driver, a Redis client, or any other asynchronous library speak the same I/O language without depending on one another.

For example, an HTTP request coroutine should be able to call an asynchronous Postgres query directly. Skein should not need to know that the nested call is Postgres; Postgres should not need to import Skein; and application code should not need a `PgAdapter`, an `async_event` hook, or a `dispatch_link()` switch.

The common boundary is made of generation-checked `Link` and `Timer` handles, numeric socket addresses, normalized errors, nonblocking TCP operations, wait interests, portable completions, timers, and cross-thread wakeups.

## Goals

1. **Interoperability:** any async client library can use the same provider contract as any framework.
2. **No framework-to-library coupling:** Skein does not import Postgres; Postgres does not import Skein. The same applies to Redis, HTTP clients, and future libraries.
3. **Portable semantics:** consumers use `Link`, `WaitSet`, `Completion`, and normalized errors—not epoll descriptors, IOCP completion keys, or io_uring user data.
4. **Replaceable providers:** consumers can use the reference backend or an existing optimized event loop that implements the same contract.
5. **Small scope:** no HTTP, TLS, SQL, proxy routing, connection-pool policy, health checks, failover, or deployment management.
6. **Explicit ownership:** handles are worker-affine; reads use caller-owned buffers; writes may be partial; cancellation and deadlines have defined semantics.

## What goose-io is

There are two pieces:

- **The shared contract** is the API and behavioral rules. Frameworks and asynchronous libraries depend on this.
- **The reference provider** is a ready-to-use implementation of that contract. Its first backend is Linux epoll.

A reactor waits efficiently for OS events, manages registrations, timers and wakeups, and translates native notifications into portable completions. The Linux provider also supplies nonblocking TCP primitives, so it can be used directly without another networking package.

A reactor is **not** a TCP proxy engine. It does not implement tcprouter's routing, TLS SNI inspection, forwarding pump, retry policy, buffer pool, lease fencing, or per-worker connection policy.

**tcprouter does not need to replace its existing worker/epoll engine with `EpollIo`.** Its current loop is tuned for proxying. tcprouter can implement the same provider contract over its existing engine. `EpollIo` is the generic reference implementation for frameworks and libraries that do not already have a suitable event loop.

## Architecture

```text
  Skein / another HTTP framework       goose-postgres / Redis / HTTP client
                  \                              /
                   \---- shared I/O contract ---/
                                |
              Link, Timer, WaitSet, Completion,
                nonblocking TCP operation rules
                                |
                    provider implementation
                       /                 \
                      /                   \
          goose-io EpollIo             tcprouter Worker
          (reference provider)         (optimized provider)
                    |
             Linux epoll + TCP
```

The framework scheduler records which coroutine frame yielded each interest. The reactor reports a completion for a resource; it does not know which library or application operation owns that wait. A wait set can combine socket readiness with a deadline. The scheduler resumes the matching frame and removes losing registrations.

Goose's coroutine/runtime support is a prerequisite for the fully sequential-looking `await` experience. This repository defines the provider and wait/completion seam; it does not implement the coroutine compiler or a general task scheduler.

## Why readiness + nonblocking operations are the v1 contract

Linux epoll and BSD kqueue naturally report readiness: a socket may be read or written now. The consumer then performs a nonblocking operation and handles partial progress or `WouldBlock`.

Windows IOCP and Linux io_uring are completion-oriented internally. Their providers can translate native results into the same portable contract. OS-specific mechanisms stay behind the backend boundary.

Reads write into caller-owned buffers. A readiness completion tells the coroutine to retry `try_read`. Writes return partial progress; the caller retains and retries the unwritten suffix. This avoids imposing tcprouter's borrowed pooled-buffer lifetime on every backend. A later owned-buffer or borrowed-slice extension must define explicit leases and cancellation.

## Linux reference provider

`reactor/epoll.goose` and `shim/epoll.c` provide:

- epoll and an `eventfd` for cross-thread wakeups;
- nonblocking, close-on-exec IPv4/IPv6 TCP listeners and accepted sockets;
- nonblocking outbound connect and connect-result detection;
- partial nonblocking reads/writes, TCP half-close, graceful close, and RST close;
- generation-checked `Link` and `Timer` slots;
- level-triggered readiness registration and normalized accept/connect/read/write/EOF/error completions;
- monotonic one-shot timers integrated into the epoll timeout;
- negative-errno native returns and normalized `IoErrorKind` values.

The native shim follows tcprouter's proven low-level approach: construct `sockaddr` in C, isolate epoll's platform-specific event layout, create nonblocking sockets, use `MSG_NOSIGNAL`, and return negative errno values. It does not copy tcprouter's proxy engine.

## Optimized Linux engines

The Linux backend also exposes a raw epoll fast path for an existing reactor
that already owns its connection table and dispatch loop. It passes native
epoll masks and 64-bit event keys through unchanged, allowing edge-triggered
engines to keep their packed event dispatch and batching without per-event
normalization. This is a Linux-specific optimization capability, not the
portable contract.

tcprouter uses this path on its `integrate/goose-io` branch. Its worker,
edge-triggered forwarding pump, buffer pool, backpressure and generation
checks remain tcprouter-owned. The standalone `EpollIo` remains the generic
reference provider for frameworks without an existing optimized loop.

## Current backend support

| Backend | Status |
|---|---|
| Linux epoll | Reference provider implemented; native C integration test included |
| Linux io_uring | Roadmap; not implemented |
| macOS / BSD kqueue | Roadmap; not implemented |
| Windows IOCP | Roadmap; not implemented |

The contract is intended to keep backends interchangeable, but cancellation races, in-flight buffers, and completion ordering still need backend-specific conformance testing before those platforms can be called supported.

## Build and tests

Run the native Linux shim test without the Goose compiler:

```bash
gcc -std=c11 -O2 -Wall -Wextra -Werror \
  tests/native/epoll_smoke.c shim/epoll.c \
  -o /tmp/goose-io-epoll-smoke
/tmp/goose-io-epoll-smoke
```

The smoke test covers epoll add/modify/delete, readable/writable notifications, repeated eventfd wakeups, IPv4 listen/connect/accept, data transfer, peer half-close, and the monotonic clock.

**Important:** the native C test does not compile or validate the Goose wrapper. The Goose compiler is not available in this environment, so the Goose source and Lit test still need to be checked with the target compiler.

## Package layout

- `core/io/types.goose` — handles, address/error types, wait sets, interests, completions.
- `core/io/contract.goose` — generic provider entry points.
- `reactor/epoll.goose` — reusable Linux epoll/TCP provider.
- `shim/epoll.c` — syscall and epoll ABI boundary.
- `tests/native/` — native C integration smoke test.
- `tests/lit/` — Goose-side provider tests.
- `docs/architecture.md` — component boundaries and design rationale.
- `docs/contract.md` — normative provider semantics.
- `docs/backend-matrix.md` — backend roadmap and conformance gates.

## License

Apache-2.0. See `LICENSE`.
