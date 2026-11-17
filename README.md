# goose-io

[![linux-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=linux-x64&label=linux-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![macos-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=macos-x64&label=macos-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![macos-arm64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=macos-arm64&label=macos-arm64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)
[![windows-x64](https://img.shields.io/github/actions/workflow/status/BHare1985/goose-io/ci.yml?branch=main&job=windows-x64&label=windows-x64)](https://github.com/BHare1985/goose-io/actions/workflows/ci.yml)

**goose-io is a pure-Goose I/O contract between event loops and the libraries that run on them.**

An event loop moves bytes over sockets. A library speaks a protocol on top of it: a Postgres client, a Redis client,
an HTTP server, a proxy. The contract between the two is a small set of types, operations and events,
with the rules that make them mean the same on every event loop. A library written against it does not
know which event loop is underneath, and an event loop does not know which libraries run on it.

Here, *event loop* means whatever drives connections and time under the contract: an operating-system poller such as
epoll, a completion ring such as io_uring, a userspace network stack, an in-memory simulator for tests, or a layer
(logging, TLS, a test shim) over another event loop.

### Write network code once, run it on any event loop

- **Library authors** write a server or a client once, and it runs on every event loop that meets the contract.
- **Event loop authors** supply the contract once, and every library written for it runs on their loop.
- **Flexible by design.** The core is what most networking code needs from a stream connection: listen, dial, send,
  receive, close and timers. It fits servers, clients, proxies, pooled connections and request/response or streaming
  protocols alike. It does not care how the event loop gets its events (epoll, io_uring, libuv, uSockets, or
  no operating-system sockets at all, as in the in-memory loop used for tests), and a layer can sit over an event loop
  with the same contract on both sides: a logging layer, a test shim, in time a TLS layer. What goes beyond the core (half-close, sizing, abort, inspection, batching, unix) is an optional group that a library asks
  for by name and an event loop supplies if it can.
- **Not covered:** name resolution, TLS and UDP (see `docs/contract.md`, "What the contract does not
  cover").

**Which of these are you?**

| | **I am writing something that talks over the network** | **I am writing an event loop** |
|---|---|---|
| You write | a library: a state struct and one function that handles events | the 12 operations of the core, on top of your sockets |
| You get | code that is not tied to an event loop, and tests that need no network | every library written for the contract, and a conformance suite that tells you when you are done |
| Start with | [the echo server](#i-am-writing-something-that-talks-over-the-network) | [the smallest event loop](#i-am-writing-an-event-loop) |

## I am writing something that talks over the network

A library handles five core events (`Opened`, `Data`, `Writable`, `Closed`, `Tick`; `PeerEof` and `PassEnd` belong to
optional groups) and calls a handful of operations
(`send`, `close`, `dial`, `listen`, ...). That is its whole interface to the network: no sockets, file descriptors,
poll masks or registered callbacks.

- **Portable.** The same source runs on every event loop that meets the contract.
- **Testable without a network.** A test runs your library on an in-memory event loop with scripted peers and a clock
  that moves only when nothing else can happen, so a test gives the same events at the same times on every run, and a
  timeout test takes no time.
- **Honest about what it needs.** A library's header says what it uses (`Needs: core only`). On an event loop that
  lacks it, the library fails to compile and the error names the missing operation.
- **Small.** The core is 12 operations and 5 events.

### The example: an echo server

The smallest library there is: every byte a peer sends comes back. The part that matters is below (the whole library is
[`examples/echo/echo.goose`](examples/echo/echo.goose), about 130 lines). It sends what arrived; if the event loop
says `Full` because the peer is not reading, it keeps the bytes, stops reading from that peer with `pause_reading`,
and carries on when the event loop says `Writable`. A slow peer cannot make the server's memory grow without bound.

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

An application runs it by handing each event to the library. This is the test that runs on every change. It runs on
the in-memory loop and uses that loop's scripted-peer helpers (`add_peer`, `peer_send`, `peer_received`, which are
not part of the contract) to play a client:

<!-- excerpt: tests/examples/echo_test.goose#echoes -->
```goose
fn echoes<Io>(io: Io&) {
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    kit::check(e.start(io, "127.0.0.1:7000"), "the echo server listens");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7000", 0);
    io.peer_send(p, 5, "hello ");
    io.peer_send(p, 10, "world\n");
    io.serve() { io, ev => on_event(e, log, io, ev, 200); };
    kit::check(io.peer_received(p) == "hello world\n", "the bytes come back, in order");
}
```

Run it, and the same test on a test layer that scrambles every byte in transit (and delays `Opened` by a pass), and on an event loop that supplies nothing but the core:

```bash
goose run tests/examples/echo_test.goose
tests/examples/over_wrapper.sh
```

**Next:** [docs/libraries.md](docs/libraries.md) is the guide to writing and testing a library. Two bigger examples
are in `examples/`: a line server (`lineserver/`) and a pooled line client (`lineclient/`), and `gateway.goose` runs
both on one loop, neither knowing the other exists.

## I am writing an event loop

An event loop owns the thread and the sockets. If yours supplies the contract,
every library written for it runs on yours, and you wrote none of them.

- **A bounded job.** The core is 12 operations and 5 events. Anything else (half-close, sizing, abort, inspection,
  batching, unix) is an optional group: supply it when you can, leave it out when you cannot. Libraries that need a
  group you lack fail to build and say which operation is missing.
- **You know when you are done.** The conformance suite checks the core and each group on its own, with both ends of
  every link on your loop. When it passes, you can list your event loop in the table below.
- **Keep your design.** The contract exposes no file descriptor, socket address or poll mask. An in-memory loop with no
  operating-system sockets conforms, and so can a completion loop built on io_uring.

### The example: the smallest event loop

[`tests/support/core_only.goose`](tests/support/core_only.goose) supplies the 12 operations of the core and nothing
else. It sits over the in-memory loop, so it is the shape of an event loop and not a real socket one: copy its list of
operations, and replace its calls to `inner` with your own socket and polling code. The suite runs on it:

```bash
tests/conformance/run.sh --core-only           # the core of the suite, on a loop that supplies nothing else
tests/conformance/run.sh                       # the core and every group, on the in-memory loop
```

**Next:** [docs/event-loops.md](docs/event-loops.md) says what to supply, shows the program that runs the suite on
your loop and how to read a failure. [docs/event-loops/](docs/event-loops/) maps candidate event loops (an epoll loop, uSockets,
io_uring, libuv, libevent) onto the contract.

## What could run on it

These are candidates, not claims: today only the in-memory event loop exists, and `docs/event-loops/` maps the first
few in detail. They show how much one contract could unify.

**Under it (event loops).** Anything that can deliver the five core events and perform the 12 operations.

- Pollers and reactors: [uSockets](https://github.com/uNetworking/uSockets), [libuv](https://github.com/libuv/libuv),
  [libevent](https://github.com/libevent/libevent), [libev](http://software.schmorp.de/pkg/libev.html),
  [libhv](https://github.com/ithewei/libhv), [picoev](https://github.com/kazuho/picoev), the loop of
  [Redis](https://github.com/redis/redis) (`src/ae.c`), the socket layer of [H2O](https://github.com/h2o/h2o)
- Completion rings and thread-per-core engines: [liburing](https://github.com/axboe/liburing),
  [libxev](https://github.com/mitchellh/libxev), [UCall](https://github.com/unum-cloud/UCall),
  [Seastar](https://github.com/scylladb/seastar)
- Userspace network stacks, with no operating-system sockets: [F-Stack](https://github.com/F-Stack/f-stack) (FreeBSD's
  stack over DPDK), [lwIP](https://savannah.nongnu.org/projects/lwip/) (embedded), [mTCP](https://github.com/mtcp-stack/mtcp),
  [smoltcp](https://github.com/smoltcp-rs/smoltcp), [gVisor's netstack](https://github.com/google/gvisor)
- Layers over another event loop, which have no loop of their own: TLS ([BearSSL](https://www.bearssl.org/),
  [s2n-tls](https://github.com/aws/s2n-tls), [Mbed TLS](https://github.com/Mbed-TLS/mbedtls),
  [wolfSSL](https://github.com/wolfSSL/wolfssl)), and engines that present streams as links
  ([MsQuic](https://github.com/microsoft/msquic), [LSQUIC](https://github.com/litespeedtech/lsquic),
  [quiche](https://github.com/cloudflare/quiche)); also metering, rate limiting and fault injection
- Simulators and fuzzers, for tests with a virtual clock and no network: the in-memory loop here,
  [libEpollFuzzer](https://github.com/uNetworking/libEpollFuzzer) and [turmoil](https://github.com/tokio-rs/turmoil)
  as the same idea elsewhere; [NNG](https://github.com/nanomsg/nng) is worth reading for how it separates transports,
  listeners and dialers

**On it (libraries).** Each is written once and runs on every event loop above.

- Servers: HTTP/1.1 and HTTP/2, WebSocket, gRPC, MQTT, SSH, SMTP and IMAP
- Clients: Postgres, MySQL, Redis, Memcached, NATS, Kafka
- Infrastructure: reverse proxies, load balancers, connection pools, SOCKS5 and HTTP `CONNECT` forwarders, ACME clients
- Distributed systems: Raft, gossip and other replication, tested on the in-memory loop with a virtual clock, so a
  timeout, a slow peer or a silent one is a few lines of test and not a lab

## Where it stands

Version 0.3 of the contract, built and tested on linux-x64, macos-x64, macos-arm64 and windows-x64. Nothing here opens
a socket or builds C: the package is Goose source and links nothing.

| Event loop | Contract | Core | Groups | Where |
|---|---|---|---|---|
| in-memory (`memory.goose`) | 0.3 | yes | half-close, sizing, abort, inspection, batching, unix | this repository |
| wrapper over it (`tests/support/wrapper.goose`) | 0.3 | yes | half-close, sizing, abort, inspection, batching, unix | this repository |
| core only (`tests/support/core_only.goose`) | 0.3 | yes | none | this repository |

**Honestly:** the one working event loop today is the in-memory one, which is for tests. An event loop on real sockets
(an optimized epoll loop) is planned as its own change (`openspec/changes/epoll-event-loop/`), and so are
uSockets and io_uring. A library written now runs on them when they land.

**What it is not.** Not an event loop (those are separate; they are mapped here, not built), and not a protocol
library: no HTTP, SQL, Redis, routing or pooling. The limits of the contract (name resolution, TLS, UDP)
are in `docs/contract.md`, "What the contract does not cover".

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
- `bench/`: micro-benchmarks, built with `goose build` and run by hand; `README.md` indexes them and holds their results (`link_map_bench.goose`: what a table keyed by link costs)
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
