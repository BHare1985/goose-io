# goose-io

[![linux-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=linux-x64&label=linux-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![macos-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=macos-x64&label=macos-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![macos-arm64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=macos-arm64&label=macos-arm64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![windows-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=windows-x64&label=windows-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)

### Write your network code once. Run it on any event loop.

goose-io is a small, pure-Goose contract between **the code that talks to the network** (a server, a client, a proxy:
a *library*) and **the engine underneath that moves the bytes** (an epoll loop, io_uring, libuv, uSockets: an *event
loop*). Your code says "send these bytes" and "here is what arrived". It never names epoll, never holds a callback,
and never learns which engine it is on. Swap the engine and your code does not change.

**Which of these are you?**

| | **I am writing something that talks over the network** | **I am writing an event loop** (the engine) |
|---|---|---|
| You want | a server, a client or a protocol that works on every engine, and tests that need no network | to put an engine under every library written for the contract |
| You write | a library: a state struct and one function that handles events | the 13 operations of the core, on top of your sockets |
| You get | portability, a virtual clock for deterministic tests, and a compile error that names what an engine lacks | every library for free, and a conformance suite that tells you when you are done |
| Start with | [The echo server](#i-am-writing-something-that-talks-over-the-network) | [The smallest event loop](#i-am-writing-an-event-loop) |

## I am writing something that talks over the network

**Write it once.** A library on goose-io handles five events (`Opened`, `Data`, `Writable`, `Closed`, `Tick`) and calls
a handful of operations (`send`, `close`, `dial`, `listen`, ...). That is the whole interface to the network: no
sockets, no file descriptors, no poll masks, no callbacks to register.

- **Runs anywhere.** The same source runs on every event loop that meets the contract, today and later.
- **Test without a network.** A test runs your library on an in-memory event loop with scripted peers and a clock that
  moves only when nothing else can happen, so a test gives the same events at the same times on every run, and a
  timeout test takes no time.
- **Needs only what it says.** A library's header says what it uses (`Needs: core only`). On an event loop that lacks
  one, it fails to compile and the error names the missing operation, not somewhere deep inside your code.
- **Small.** The core is 13 operations and 5 events. No callbacks to register, no threads to manage: events come in, calls go out.

### The example: an echo server

The smallest library there is: every byte a peer sends comes back. The part that matters is below (the whole library is
[`examples/echo/echo.goose`](examples/echo/echo.goose), about 130 lines). It sends what arrived; if the event loop
says `Full` because the peer is not reading, it keeps the bytes, stops reading from that peer with `pause_reading`,
and carries on when the event loop says `Writable`. A slow peer cannot make the server grow.

<!-- excerpt: examples/echo/echo.goose#on_data -->
```goose
fn _on_data<Io>(e: Echo&, io: Io&, c: Conn&, bytes: const u8[:]) {
    if c.held.len == 0 {
        let status = io.send(c.link, bytes);
        if status == goose_io::SendStatus.Sent { return; }
        if status != goose_io::SendStatus.Full { io.close(c.link); return; }
        e.refused++;
    }
    if c.held.len + bytes.len > HOLD { io.close(c.link); return; }
    c.held.append(bytes);
    io.pause_reading(c.link, true);
}
```

An application runs it by handing each event to the library. This is the test that runs on every change, and it
plays the peer for you:

<!-- excerpt: tests/examples/echo_test.goose#echoes -->
```goose
fn echoes<Io>(io: Io&) {
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    kit::check(e.start(io, "127.0.0.1:7000", 1), "the echo server listens");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7000", 0);
    io.peer_send(p, 5, "hello ");
    io.peer_send(p, 10, "world\n");
    io.serve() { io, ev => on_event(e, log, io, ev, 200); };
    kit::check(io.peer_received(p) == "hello world\n", "the bytes come back, in order");
}
```

Run it, and the same test on an event loop that changes every byte and one that supplies nothing but the core:

```bash
goose run tests/examples/echo_test.goose
tests/examples/over_wrapper.sh
```

**Next:** [docs/libraries.md](docs/libraries.md) is the guide to writing and testing a library. Two bigger examples
are in `examples/`: a line server (`lineserver/`) and a pooled line client (`lineclient/`), and `gateway.goose` runs
both on one loop, neither knowing the other exists.

## I am writing an event loop

**Plug in once, run every library.** An event loop owns the thread and the sockets. If yours supplies the contract,
every library written for it runs on yours, and you wrote none of them.

- **A small job.** The core is 13 operations and 5 events. Anything else (half-close, sizing, abort, inspection,
  batching) is an optional group: supply it when you can, leave it out when you cannot. Libraries that need a
  group you lack fail to build and say which operation is missing.
- **You know when you are done.** The conformance suite checks the core and each group on its own, with both ends of
  every link on your loop. When it passes, you are listed.
- **Keep your design.** The contract exposes no file descriptor, socket address or poll mask. An event loop built on
  nothing at all (the in-memory one) conforms, so can one built on io_uring.

### The example: the smallest event loop

[`tests/support/core_only.goose`](tests/support/core_only.goose) supplies the 13 operations of the core and nothing
else. It sits over the in-memory loop, so it is the shape of an event loop and not a real socket one: copy its list of
operations, and put your sockets where it calls `inner`. The suite runs on it:

```bash
tests/conformance/run.sh --core-only           # the core of the suite, on a loop that supplies nothing else
tests/conformance/run.sh                       # the core and every group, on the in-memory loop
```

**Next:** [docs/event-loops.md](docs/event-loops.md) says what to supply, shows the program that runs the suite on
your loop and how to read a failure. [docs/event-loops/](docs/event-loops/) maps tcprouter's engine, uSockets and
io_uring onto the contract.

## Where it stands

Version 0.1 of the contract, built and tested on linux-x64, macos-x64, macos-arm64 and windows-x64. Nothing here opens
a socket or builds C: the package is Goose source and links nothing.

| Event loop | Contract | Core | Groups | Suite last passed at | Where |
|---|---|---|---|---|---|
| in-memory (`memory.goose`) | 0.1 | yes | half-close, sizing, abort, inspection, batching | `650c8c5` | this repository |
| wrapper over it (`tests/support/wrapper.goose`) | 0.1 | yes | half-close, sizing, abort, inspection | `650c8c5` | this repository |
| core only (`tests/support/core_only.goose`) | 0.1 | yes | none | `650c8c5` | this repository |

**Honestly:** the one working event loop today is the in-memory one, which is for tests. An event loop on real sockets
(epoll, from tcprouter's engine) is planned as its own change (`openspec/changes/epoll-event-loop/`), and so are
uSockets and io_uring. A library written now runs on them when they land.

**What it is not.** Not an event loop (those are separate; they are mapped here, not built). Not a protocol library:
no HTTP, TLS, SQL, Redis, routing or pooling. Not name resolution, TLS, UDP or Unix sockets (`docs/contract.md`,
"What the contract does not cover").

## Try it

You need the Goose toolchain (v2026.4). From the root of this repository:

```bash
goose check goose_io.goose                      # the contract compiles
tests/run_tests.sh                              # unit tests, driver tests, example library tests
tests/conformance/run.sh                        # the conformance suite on the in-memory event loop
tests/conformance/run.sh --repeat 50            # fifty times: a check that fails once fails the run
tests/conformance/faults.sh                     # every check is shown to fail when the event loop is broken
```

## Repository layout

- `goose_io.goose`: the contract: the types, the helpers, the version and `require_core` with one check for each group
- `deadlines.goose`: `Deadlines`, a bounded heap of deadlines for libraries that have many
- `memory.goose`: the in-memory event loop, with scripted peers, a virtual clock and the named faults
- `conformance/`: the conformance suite, which imports only the contract: `suite.goose` is the driver and the entry points, `support.goose` what every check shares, `handles`, `net`, `data`, `close` and `time` the checks
- `examples/`: the example libraries: `echo/`, `lineserver/`, `lineclient/` and `gateway.goose`, which runs the last two on one loop
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

- [`docs/libraries.md`](docs/libraries.md): how to write a library and how to test it.
- [`docs/event-loops.md`](docs/event-loops.md): how to write an event loop, run the suite, and which check proves which requirement.
- [`docs/contract.md`](docs/contract.md): the contract, operation by operation, with the rules and the version.
- [`docs/event-loops/`](docs/event-loops/): how each candidate event loop maps onto the contract.
- [`docs/history.md`](docs/history.md): where this repository started and what was run when.

## License

Apache-2.0. See `LICENSE`.
