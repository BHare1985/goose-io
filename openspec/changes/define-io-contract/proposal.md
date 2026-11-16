# Proposal

## Why

Every Goose networking stack (tcprouter/skein, goose-http, goose-wing, gsal) owns its own event loop, socket handles and wakeups, so an async client library has to be written against one of them: goose-postgres's `pool.goose` imports goose-http directly, and skein carries about 155 lines of adapter glue to reach Postgres over tcprouter. goose-io exists to end that, but what is in the repository today was written without a compiler: the Goose sources do not parse on v2026.4, only the C shim has ever run, and the contract it sketches (caller-owned read buffers, partial writes, a watch/unwatch call per wait) is neither what tcprouter does nor what an io_uring loop can provide without extra copies.

tcprouter's engine already contains a proven, benchmarked answer: its handler API (`Opened`, `Data`, `Writable`, `PeerEof`, `Closed`, `Tick`, `PassEnd`, `send`, `dial`) is used by skein for both HTTP connections and outbound database links. Lifting that API into a provider-neutral contract, and that engine into a reference implementation, gives the ecosystem one target and lets tcprouter adopt it without changing how it runs.

## What Changes

- **BREAKING** Replace the unvalidated contract in `core/io/` (`WaitSet`, `Interest`, `Completion`, `try_read`, `try_write`, `watch`, `unwatch`, `poll`) with an event contract: a provider delivers events for a link, and a library answers with a small set of calls. Nothing released depends on the old shape; the only consumer is an unmerged, never-compiled tcprouter branch pinned to a commit hash.
- Define the contract so both readiness loops (epoll, kqueue) and completion loops (io_uring, IOCP) can provide it: received bytes arrive as a slice the provider owns for the duration of the event, and a send is either accepted whole by the provider or refused with a later `Writable`.
- Add a reference epoll provider by moving the generic half of tcprouter's engine into goose-io: the worker loop, slot and generation handles, buffer pool, send queue, dial, half-close, timeouts, pass-end batching, drain and statistics. Remove the current `reactor/epoll.goose` and the level-triggered parts of `shim/epoll.c`.
- Add an extension seam to the reference provider (compile-time hooks, empty by default) so tcprouter can later plug its routing, SNI inspection, forwarding pump, policy and fences into the same loop. tcprouter's forwarding stays tcprouter's code; it is not part of the contract.
- Add a conformance suite that any provider can be run against, an in-memory fake provider for deterministic tests without sockets, and one example client library written only against the contract and run unchanged on both providers.
- Add performance gates against tcprouter `main` on the handler path: identical syscalls per request, and throughput, p99 and CPU per request no worse than the baseline's own run-to-run spread.
- Rewrite `README.md` and `docs/` to describe what exists and has been verified.

Out of scope, each a later change or a separate project:

- Refactoring tcprouter onto goose-io. This change ends when goose-io is ready for that work; "identical behaviour and performance" is that project's gate.
- An io_uring reference provider based on c_proxy. It is the next goose-io change and must pass the same conformance suite.
- Coroutine (`coro fn`) integration, DNS, TLS, UDP, Unix sockets, files, and cross-thread messaging.

## Capabilities

### New Capabilities

- `io-contract`: the provider-neutral contract between an event loop and the libraries that run on it: link handles, the event set and its ordering guarantees, listening and dialling, sending with backpressure, closing and half-close, ticks and deadlines, pass-end batching, and close reasons.
- `epoll-engine`: the reference Linux epoll provider: worker lifecycle, limits, timeouts, drain, statistics, the extension seam for engines that add their own connection states, and the performance gates it must hold against tcprouter.
- `provider-conformance`: what it means for a provider to conform: the conformance suite, the fake provider, the example client library, and how a new provider is admitted.

### Modified Capabilities

None. The project has no specs yet.

## Impact

- **goose-io code:** `core/io/types.goose`, `core/io/contract.goose`, `reactor/epoll.goose`, `shim/epoll.c`, `tests/lit/`, `tests/native/`, `goose_io.goose`, `goose-io.build`, `Justfile`, the CI workflow, `README.md` and everything under `docs/` are replaced or rewritten.
- **tcprouter:** read-only source for this change. Engine code is copied from `~/dev/cnamecloud/tcprouter` (`engine.goose`, `conn.goose`, `handler.goose`, `messages.goose`, `address.goose`, `sys.goose`, `src/c_sys.c`) together with the tests that cover it. tcprouter's `integrate/goose-io` branch becomes obsolete; its pinned commit stays resolvable.
- **skein, goose-postgres, goose-http, goose-wing:** not modified. They are the intended adopters, and their existing shapes informed the contract.
- **Visibility:** tcprouter's repository is private and goose-io is referenced by a public import path, so this moves engine code into goose-io. The owner of both has asked for that.
- **Toolchain:** Goose v2026.4, Linux, Python 3 for the network test drivers, `strace` and `wrk` for the performance gates.
