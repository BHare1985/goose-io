# goose-io

**One I/O contract between an event loop and the libraries that run on it, in pure Goose.**

A Postgres client, a Redis client and an HTTP server should not each need to know which event loop they run on, and
no event loop should need its own copy of each. goose-io is the contract between "the loop" (a *provider*) and "a
library on the loop": a small set of types, operations and events, with the rules that make them mean the same on every
provider. A library written once runs on every provider that passes the conformance suite.

Version 0.1 of the contract, an in-memory provider for testing, a provider-neutral conformance suite and two example
libraries. Nothing here opens a socket or builds C: the package is Goose source and links nothing.

## What it is not

- **Not an event loop.** Providers (tcprouter's engine, uSockets, io_uring, libuv, libevent) are separate; they are
  mapped, not implemented, here (`docs/providers/`). The in-memory provider is the one working implementation.
- **Not a protocol library.** No HTTP, TLS, SQL, Redis, routing, pooling or health checks. The two example libraries
  (a line server and a pooled line client) show the shape of one.
- **Not name resolution, TLS, UDP or Unix sockets.** See `docs/contract.md`, "What the base contract does not cover".

## The contract in one screen

Events go in, calls go out. The host runs the loop and hands every event to its libraries; a library keeps its own
state and answers with calls. Nothing is stored as a callback. Full text: `docs/contract.md`.

```text
types       Link { slot, gen }   Listener { id }   Address   SendStatus   CloseReason   ListenError   Event

listen(address, tag) -> Listener, ListenError      listener_port(l)      stop_listening(l)
dial(address, tag, connect_ms) -> Link             peer_address(link)
send(link, bytes) -> SendStatus                    send2(link, first, second)    send_room(link)    max_send()
pause_reading(link, paused)                        set_keep_open_on_eof(link, keep)
shutdown_write(link)    close(link)    reset(link) set_user(link, u32)    user(link)
now_ms()    tick_by(at_ms)                         serve() { io, ev => ... }    stop(grace_ms)    draining()

events      Opened  Data  Writable  PeerEof  Closed  Tick  PassEnd
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
```

## How to test a library

`memory.goose` is a provider with no sockets and a clock that moves only when the loop has nothing left to do, so a test
gives the same events at the same times on every run. A test plays the other end of each link with a scripted peer and
reads back what the library sent. `docs/libraries.md` has the guide, and its example is a test that runs:

```bash
goose run tests/unit/library_example_test.goose
```

The example libraries are `examples/lineserver/`, `examples/lineclient/` and `examples/gateway.goose`; their tests are in
`tests/examples/`:

```bash
goose run tests/examples/gateway_test.goose
tests/examples/over_wrapper.sh                  # the same tests over a provider that changes every byte
```

## How to run the suite on a provider

The suite is written only against the contract and is generic over the provider. A provider's root program builds its
loop, a small fixture (an address that never answers, an address that is already held) and calls
`conformance_part`. `docs/providers.md` shows the program and says how to read a failure. For the in-memory provider:

```bash
tests/conformance/run.sh                        # every part, one process each
tests/conformance/run.sh --repeat 50            # fifty times: a check that fails once fails the run
tests/conformance/faults.sh                     # every check is shown to fail when the provider is broken
```

## Conforming providers

A provider is listed only after the whole suite has passed against it, with the contract version and the commit.

| Provider | Contract | Suite last passed at | Where |
|---|---|---|---|
| in-memory (`memory.goose`) | 0.1 | `5af3525` | this repository |
| wrapper over it (`tests/support/wrapper.goose`) | 0.1 | `5af3525` | this repository |

Planned example providers, each its own change: tcprouter's engine (with performance-parity gates), uSockets, io_uring.
How every operation and event maps onto each, and what is still unverified, is in `docs/providers/`.

## Repository layout

- `goose_io.goose`: the contract: the types, the helpers, the version and `require_provider`
- `deadlines.goose`: `Deadlines`, a bounded heap of deadlines for libraries that have many
- `memory.goose`: the in-memory provider, with scripted peers, a virtual clock and the named faults
- `conformance/`: the conformance suite, which imports only the contract: `suite.goose` is the driver and entry point, `support.goose` what every check shares, `handles`, `net`, `data`, `close` and `time` the checks
- `examples/`: the example libraries: `lineserver/`, `lineclient/` and `gateway.goose`, which runs both on one loop
- `docs/`: `contract.md`, `libraries.md`, `providers.md` and `history.md`
- `docs/providers/`: how each candidate provider maps onto the contract
- `tests/unit/`: tests of the types, `Deadlines` and the in-memory provider
- `tests/examples/`: tests of the example libraries, and the scripts that run them over the wrapper
- `tests/conformance/`: running the suite (`run.sh`, `faults.sh`, `table_check.sh`), the table of checks and faults (`checks.tsv`), and the driver's own tests
- `tests/support/`: what tests share: `kit.goose` (the test kit) and `wrapper.goose` (a provider layered over another)
- `tests/checks/`: scripts that check the repository itself: quoted code, purity, provider mappings, this layout
- `tests/run_tests.sh`: runs every `*_test.goose` and `*_mustfail.goose` and the purity check
- `openspec/`: the specification and the changes that made it
- `Justfile`: `just check`, `just test`, `just fmt`
- `CONTRIBUTING.md`: what to run before sending a change, and how to add a provider
- `README.md`: this file
- `LICENSE`: Apache-2.0

## Documents

- `docs/contract.md`: the contract, operation by operation, with the rules and the version.
- `docs/libraries.md`: how to write a library and how to test it.
- `docs/providers.md`: how to write a provider, run the suite, and which check proves which requirement.
- `docs/providers/`: how each candidate provider maps onto the contract.
- `docs/history.md`: where this repository started and what was run when.

## License

Apache-2.0. See `LICENSE`.
