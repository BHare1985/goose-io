# goose-io

[![linux-x64](https://github.com/BHare1985/goose-io/actions/workflows/ci-linux-x64.yml/badge.svg?branch=main)](https://github.com/BHare1985/goose-io/actions/workflows/ci-linux-x64.yml)
[![macos-x64](https://github.com/BHare1985/goose-io/actions/workflows/ci-macos-x64.yml/badge.svg?branch=main)](https://github.com/BHare1985/goose-io/actions/workflows/ci-macos-x64.yml)
[![macos-arm64](https://github.com/BHare1985/goose-io/actions/workflows/ci-macos-arm64.yml/badge.svg?branch=main)](https://github.com/BHare1985/goose-io/actions/workflows/ci-macos-arm64.yml)
[![windows-x64](https://github.com/BHare1985/goose-io/actions/workflows/ci-windows-x64.yml/badge.svg?branch=main)](https://github.com/BHare1985/goose-io/actions/workflows/ci-windows-x64.yml)

**One I/O contract between an event loop and the libraries that run on it, in pure Goose.**

A Postgres client, a Redis client and an HTTP server should not each need to know which event loop they run on, and
no event loop should need its own copy of each. goose-io is the contract between "the loop" (an *event loop*: epoll,
uSockets, io_uring, libuv or one you write) and "a library on the loop": a small set of types, operations and events,
with the rules that make them mean the same on every event loop. A library written once runs on every event loop that
supplies what the library uses.

The contract is a **core** that every event loop supplies (13 operations and 5 events, enough for a client or a server
that answers requests) and five **groups of extras** that it may add or leave out: half-close, sizing, abort,
inspection and batching. A library says in its header what it needs; on a loop that lacks it, it fails to compile and
the error names the missing operation. The cheapest event loop to write is one that supplies only the core.

Version 0.1 of the contract (CI builds and tests it on linux-x64, macos-x64, macos-arm64 and windows-x64), an in-memory event loop for testing, a conformance suite that is run by group, and two
example libraries. Nothing here opens a socket or builds C: the package is Goose source and links nothing.

## What it is not

- **Not an event loop.** Event loops (tcprouter's engine, uSockets, io_uring, libuv, libevent) are separate; they are
  mapped, not implemented, here (`docs/event-loops/`). The in-memory event loop is the one working implementation.
- **Not a protocol library.** No HTTP, TLS, SQL, Redis, routing, pooling or health checks. The two example libraries
  (a line server and a pooled line client) show the shape of one.
- **Not name resolution, TLS, UDP or Unix sockets.** See `docs/contract.md`, "What the contract does not cover".

## The contract in one screen

Events go in, calls go out. The application runs the loop and hands every event to its libraries; a library keeps its own
state and answers with calls. Nothing is stored as a callback. Full text: `docs/contract.md`.

```text
CORE (every event loop)
  listen(address, tag) -> Listener, ListenError     listener_port(l)        dial(address, tag, connect_ms) -> Link
  send(link, bytes) -> SendStatus                   max_send()              pause_reading(link, paused)
  close(link)    set_user(link, u32)                now_ms()                tick_by(at_ms)
  serve() { io, ev => ... }    stop(grace_ms)       draining()
  events    Opened  Data  Writable  Closed  Tick

GROUPS (an event loop may add any of them)
  half-close   shutdown_write(link)   set_keep_open_on_eof(link, keep)   event PeerEof
  sizing       send_room(link)        send2(link, first, second)
  abort        reset(link)
  inspection   peer_address(link)     stop_listening(l)    user(link)
  batching     event PassEnd
```

- **Links are handles**, a slot and a generation: a stale handle does nothing and never reaches a link that reused its slot.
- **Received bytes are lent** for one event. **Sends are taken whole or refused** (`Full`, then one `Writable`).
- **Every link ends with exactly one `Closed`**, and an operation never delivers an event from inside itself.
- **Time is the loop's** (`now_ms`, `Tick`, `tick_by`), so a test can use a virtual clock.

## Try it

You need the Goose toolchain (v2026.4). From the root of this repository:

```bash
goose check goose_io.goose                      # the contract compiles
tests/run_tests.sh                              # unit tests, driver tests, example library tests
tests/checks/docs.sh                             # code quoted in the documents is the code in the repository
tests/checks/vocabulary.sh                      # the documents and the code use "event loop", "library" and "application"
```

## How to test a library

`memory.goose` is an event loop with no sockets and a clock that moves only when the loop has nothing left to do, so a test
gives the same events at the same times on every run. A test plays the other end of each link with a scripted peer and
reads back what the library sent. `docs/libraries.md` has the guide, and its example is a test that runs:

```bash
goose run tests/unit/library_example_test.goose
```

The example libraries are `examples/lineserver/`, `examples/lineclient/` and `examples/gateway.goose`; their tests are in
`tests/examples/`:

```bash
goose run tests/examples/gateway_test.goose
tests/examples/over_wrapper.sh                  # the same tests over an event loop that changes every byte,
                                                # and the line client over a loop that supplies only the core
tests/examples/needs_check.sh                   # each library's header names the groups it calls
```

## How to run the suite on an event loop

The suite is written only against the contract, is generic over the event loop, and is divided by group: the checks of the
core call nothing outside the core, and each group has its own entry point, so a loop is tested for what it supplies. An
event loop's root program builds its loop, a small fixture (an address that never answers, an address that is already
held, an address nothing listens on) and calls the entry point of the core and of each group it supplies.
`docs/event-loops.md` shows the program and says how to read a failure. For the in-memory event loop:

```bash
tests/conformance/run.sh                        # the core and every group, one process for each part
tests/conformance/run.sh --group sizing         # one group only (core, half-close, sizing, abort, inspection, batching)
tests/conformance/run.sh --core-only            # the core, on a loop that supplies nothing else
tests/conformance/run.sh --repeat 50            # fifty times: a check that fails once fails the run
tests/conformance/faults.sh                     # every check is shown to fail when the event loop is broken
```

## Conforming event loops

An event loop is listed only after the core, and each group it claims, has passed against it, with the contract version
and the commit.

| Event loop | Contract | Core | Groups | Suite last passed at | Where |
|---|---|---|---|---|---|
| in-memory (`memory.goose`) | 0.1 | yes | half-close, sizing, abort, inspection, batching | `650c8c5` | this repository |
| wrapper over it (`tests/support/wrapper.goose`) | 0.1 | yes | half-close, sizing, abort, inspection | `650c8c5` | this repository |
| core only (`tests/support/core_only.goose`) | 0.1 | yes | none | `650c8c5` | this repository |

Planned example event loops, each its own change: tcprouter's engine (with performance-parity gates), uSockets, io_uring.
How every operation and event maps onto each, what the core alone costs each, and what is still unverified, is in
`docs/event-loops/`.

## Repository layout

- `goose_io.goose`: the contract: the types, the helpers, the version and `require_core` with one check for each group
- `deadlines.goose`: `Deadlines`, a bounded heap of deadlines for libraries that have many
- `memory.goose`: the in-memory event loop, with scripted peers, a virtual clock and the named faults
- `conformance/`: the conformance suite, which imports only the contract: `suite.goose` is the driver and the entry points, `support.goose` what every check shares, `handles`, `net`, `data`, `close` and `time` the checks
- `examples/`: the example libraries: `lineserver/`, `lineclient/` and `gateway.goose`, which runs both on one loop
- `docs/`: `contract.md`, `libraries.md`, `event-loops.md` and `history.md`
- `docs/event-loops/`: how each candidate event loop maps onto the contract
- `tests/unit/`: tests of the types, `Deadlines` and the in-memory event loop
- `tests/examples/`: tests of the example libraries, and the scripts that run them over the wrapper
- `tests/conformance/`: running the suite (`run.sh`, `faults.sh`, `table_check.sh`, `groups_check.sh`), the table of checks and faults (`checks.tsv`), and the driver's own tests
- `tests/support/`: what tests share: `kit.goose` (the test kit), `wrapper.goose` (an event loop layered over another), `core_only.goose` (an event loop that supplies only the core) and `stub.goose`
- `tests/checks/`: scripts that check the repository itself: quoted code, purity, vocabulary, event loop mappings, this layout
- `tests/run_tests.sh`: runs every `*_test.goose` and `*_mustfail.goose`, the purity check and the vocabulary check
- `openspec/`: the specification and the changes that made it
- `Justfile`: `just check`, `just test`, `just fmt`
- `CONTRIBUTING.md`: what to run before sending a change, and how to add an event loop
- `README.md`: this file
- `LICENSE`: Apache-2.0

## Documents

- `docs/contract.md`: the contract, operation by operation, with the rules and the version.
- `docs/libraries.md`: how to write a library and how to test it.
- `docs/event-loops.md`: how to write an event loop, run the suite, and which check proves which requirement.
- `docs/event-loops/`: how each candidate event loop maps onto the contract.
- `docs/history.md`: where this repository started and what was run when.

## License

Apache-2.0. See `LICENSE`.
