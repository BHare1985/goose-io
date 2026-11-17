# Writing an event loop and running the conformance suite

**In short:** you write the engine, and every library written for the contract runs on it. The job is the 13
operations and 5 events of the core, and as many of the six optional groups as you like; the conformance suite tells
you when you are done. [`tests/support/core_only.goose`](../tests/support/core_only.goose) is the smallest example of
the shape (it sits over the in-memory loop, where yours would sit over your sockets).

An event loop is the part of a program that owns a thread and its sockets and supplies the operations and events of
the contract (`docs/contract.md`). This document is for the author of one. It says what an event loop must supply
and what it may leave out, how to run the conformance suite on it, the fixture, how to read a failure and the rule
for being listed as conforming; the table that says where each requirement is proved follows.

## What an event loop must supply

The **core**, which every event loop supplies: the operations `listen`, `listener_port`, `dial`, `send`,
`max_send`, `pause_reading`, `close`, `now_ms`, `tick_by`, `serve`, `stop` and `draining`, and the
events `Opened`, `Data`, `Writable`, `Closed` and `Tick`, with the types of `goose_io.goose`, as functions that a
library calls by method syntax on the event loop's type.

And any of six **groups**, which it may supply or leave out (`docs/contract.md`, section 2):

| Group | Operations | Events |
|---|---|---|
| half-close | `shutdown_write`, `set_keep_open_on_eof` | `PeerEof` |
| sizing | `send_room`, `send2` | |
| abort | `reset` | |
| inspection | `peer_address`, `stop_listening` | |
| batching | | `PassEnd` |
| unix | the address form `unix:/path`, no operation | |

Call `goose_io::require_core(io)` once from the event loop's root program, and the check of each group it supplies
(`require_half_close`, `require_sizing`, `require_abort`, `require_inspection`; batching and unix have no operation and so no check). Each names every operation of its
part with the contract's argument and result types and never runs, so a missing or mistyped operation is a compile
error at that one line, naming the operation, and not deep inside a library. An event loop with nothing more than
the core conforms; anything it adds (name resolution, TLS, other transports) is not part of the contract and no
library may need it (*What the contract covers*). A group an event loop leaves out is a group its libraries may
not use: a library that needs `send2` fails to build on it, which is the intended answer.

## Running the suite

The suite is the directory `conformance/` (import `goose_io.conformance.suite`; the namespace is `goose_io_conformance`): `suite.goose` is the driver and the entry points, `support.goose` holds what every check shares, and `handles`, `net`, `data`, `close` and `time` hold the checks. It
imports the contract and nothing that names an event loop. **The suite is divided by group**: the checks of the core call nothing outside the core, and the checks of each group are their own entry point, so a loop is tested for what it supplies and no more. A check that needs two groups is split into one check for each (`checks.tsv` has a `group` column for every check). Both ends of every link are on the event loop under test:
a check listens on the loopback with port 0 and dials the port it was given, and makes the peer's behaviour with
contract calls (`close`, `pause_reading`, not sending; a check of a group also uses that group's operations). It therefore runs unchanged on any
event loop, over IPv4 and IPv6 loopback.

An event loop's root program constructs its loop, builds a fixture and calls the entry point of the core and of each group it supplies (`conformance_core_part`, `conformance_half_close_part`, `conformance_sizing_part`, `conformance_abort_part`, `conformance_inspection_part`, `conformance_batching_part`, `conformance_unix_part`) with a part number.
This is the program that runs the in-memory event loop, whose suite results the tests of this repository rely on:

<!-- source: tests/conformance/memory_conformance.goose -->
```goose
// Runs one part of the conformance suite against the in-memory event loop: `goose run tests/conformance/memory_conformance.goose -- 3 core`.
// The part is the first argument (default 0) and the group the second (core, half-close, sizing, abort, inspection, batching or unix; default core).
// The environment variable GOOSE_IO_FAULT, when set, switches the in-memory event loop to one of its named faults
// (see tests/conformance/faults.sh).
import std;
import os;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;

fn main() {
    var part = 0;
    if arg_count() > 1 {
        var text: u8[>..] = [];
        arg(1, text);
        part = 0;
        for c in text { if c >= '0' && c <= '9' { part = part * 10 + (c - '0'); } }
    }
    var group: u8[>..] = [];
    if arg_count() > 2 { arg(2, group); }
    var io = goose_io_memory::Loop { .. };
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
    io.silent("10.255.0.1:81");
    io.hold("127.0.0.1:9999");
    let up = io.add_peer();
    io.peer_accept(up, "10.255.0.2:80");
    let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9", answers: "10.255.0.2:80", unix: "/run/goose-io-test.sock" };
    if group == "half-close" { exit(goose_io_conformance::conformance_half_close_part(io, fixture, part)); }
    if group == "sizing" { exit(goose_io_conformance::conformance_sizing_part(io, fixture, part)); }
    if group == "abort" { exit(goose_io_conformance::conformance_abort_part(io, fixture, part)); }
    if group == "inspection" { exit(goose_io_conformance::conformance_inspection_part(io, fixture, part)); }
    if group == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    if group == "unix" { exit(goose_io_conformance::conformance_unix_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_core_part(io, fixture, part));
}
```

Only one `stop` can be observed in one `serve`, so the suite is divided into **parts** and each part is run in
its own process. Part 0 is every check that does not need `stop`, ending with *stop with nothing open*. Parts 1
to 5 are one scenario of `stop` each: a link that stays open, libraries that finish, listening while draining,
dialling while draining, and `stop` called twice. The core has parts 0 to 5; every group has part 0 only. The root program
above takes the part as its first argument and the group as its second; `tests/conformance/run.sh` runs all of them:

```
tests/conformance/run.sh                 # every part of every group once
tests/conformance/run.sh --group sizing  # one group only
tests/conformance/run.sh --repeat 50     # fifty times: any failure in any repetition fails the run
```

Each entry point returns the number of checks that failed, so `exit(...)` of it is the program's status. Time
bounds in the checks use the loop's clock (`now_ms`), so the same bounds hold on a virtual clock and on a real one.
A check that has to wait for an event loop limit it cannot know (*A peer that never reads*) allows two minutes of that
clock.

### The fixture

A fixture supplies the two things that contract calls cannot produce:

| Field | What the runner supplies |
|---|---|
| `silent` | An address to which a connect is never answered, so a dial to it ends only when its connect time passes. In the in-memory event loop, `io.silent(address)`; on a socket event loop, an address that drops packets. |
| `held` | An address on which `listen` fails with `AddressInUse`. In the in-memory event loop, `io.hold(address)`; on a socket event loop, a port another socket already holds exclusively. |
| `refused` | An address that nothing listens on, so a dial to it is refused. In the in-memory event loop any address no one listens on; on a socket loop, a port that no socket holds. |
| `answers` (optional) | An address that still accepts connections while the loop is draining. See `dial_while_draining` below. |

### Reading a failure

Each check prints `ok   <name>` or `FAIL <name> [<requirement>]: <what was wrong>`. The requirement is the name of
the requirement in `specs/io-contract/spec.md` and in `docs/contract.md` (each requirement is named there, in
italics). The suite is run one group at a time, so the process that failed says which group the requirement belongs
to: a failure in the `sizing` run is a requirement of the sizing group, and a loop that does not supply that group
need not pass it. The last line gives the number of checks run and failed. A failed check stops that check only, so one
output shows every failing requirement of the part. A check that did not finish by its deadline on the loop's
clock fails with *not finished in time*; one whose events arrive from inside another handler fails with *an event
was delivered from inside the handler of another event*.

A check that fails in any repetition is a failure until its cause has been explained: `run.sh --repeat` does not
average. On the in-memory event loop the output of every repetition is also compared with the first.

### The suite tests itself

`tests/conformance/faults.sh` switches the in-memory event loop to one named fault after another (a deliberate break
of one behaviour, listed in `tests/conformance/checks.tsv`) and requires the check for that behaviour to fail. A
check that passes against its own fault is a defect in the suite. `tests/conformance/table_check.sh` requires the
table below to name every scenario of the specification and every check of the suite.

## Being listed as conforming

An event loop is described as conforming to the core only after every part of the core has passed against it, and to
a group of extras only after that group's entry point has passed; its documentation lists the core and each
group it conforms to. Passing a group while failing the core is not conforming to anything. The runs are on the
operating system it targets, and its documentation says which contract version (`goose_io::VERSION_MAJOR` and
`VERSION_MINOR`) and which commit of the event loop that was. An event loop that fails any check of a part it claims is not listed for that part.
While the contract is at major version 0 an event loop may find that a requirement cannot be met on its backend; it
then records what it tried, and the contract is changed only if no other way works (design D13 of the change that
introduced it).

## The epoll event loop

The first event loop on real sockets is [`examples/loops/epoll/`](../examples/loops/epoll/): one `epoll::Loop` is one thread's loop,
on Linux, made from the generic layer of tcprouter's engine (the worker loop, slots and generations, the buffer pool and bounded send
queue, dial, timeouts, drain and statistics) with the proxy removed, and moved to the contract's names. It supplies the core and the
half-close, sizing, abort, inspection and batching groups; it does not supply the unix group (a `unix:` address is `BadAddress`).
It is not part of the package (the package is pure Goose): it needs a C layer for sockets and epoll, which lives under
`examples/loops/`, the one place `tests/checks/purity.sh` allows native files. [`bench/BASELINE.md`](../bench/BASELINE.md) says what it
is measured against and how.

```
import goose_io from "<this repository>";
import epoll from "<this repository>/examples/loops/epoll";

var io = epoll::Loop { .. };               // set io.limits before the first listen, dial or serve
let listener, err = io.listen("0.0.0.0:8080");
io.serve() { io, ev => handle(io, ev); };
```

A program that uses it is built with `goose build` (`examples/loops/epoll/build.sh program.goose output`); `goose run` cannot link the
loop's C layer. Several loops, one for each thread, share a port (`SO_REUSEPORT`) and are stopped together with `epoll::spawn`,
`epoll::drain` and `epoll::wait_for_signal_then_drain`; `epoll::probe(address)` first, so that a port held by another process is an
error and not a shared port. `serve` is the application's; `stop` on one loop is called on its own thread.

**How it differs from tcprouter's engine**, where the contract asked for something else: a slot is freed only after the handlers of its
`Closed` have returned (so `peer_address` works inside that handler, and a link made there cannot take the slot, a failed `dial`
included); `Writable` comes once the largest refused send would fit; `close` finishes sending, shuts the write side and drops the
peer's input in a socket of its own until the peer ends or `half_close_timeout_ms` passes, so it never resets a link with unread input;
and a Tick comes at least every 90 ms of the loop's clock (a 100 ms period plus a scheduler's slack broke the contract's 100 ms).
Everything else on the path of a request is tcprouter's, and the system calls per request are the same (`bench/gate_syscalls.sh`).

**Running the suite on it.** The runner is `examples/loops/epoll/conformance.goose`; it makes the fixture without privileges, on the
loopback: `silent` is a listener with a backlog of one whose accept queue is full and never drained (a connect is dropped, so a dial to it
ends by its own timeout), `held` a socket the runner keeps bound and listening (so `listen` on its address fails with `AddressInUse`),
`refused` a port that was bound and released, and `answers` a listener the kernel keeps completing connects for. The runner's
`half_close_timeout_ms` is 3 seconds, so that `close_when_peer_never_reads` ends in seconds and not in the two minutes the check allows.
`examples/loops/epoll/conformance.sh [--repeat N] [--group G]` builds it and runs every part of the core and of each group.

<!-- source: examples/loops/epoll/conformance.goose -->
```
// Runs one part of the conformance suite against the epoll event loop, on real sockets:
//
//     goose build conformance.goose -o conformance && ./conformance <part> <group>
//
// The part is the first argument (default 0) and the group the second (core, half-close, sizing, abort, inspection or batching;
// default core). Both ends of every link are on the loop under test, so the runner supplies what a contract call cannot make
// (docs/event-loops.md, the fixture), without privileges, on the loopback:
//
//   silent   a listener with a backlog of one whose accept queue is full and never drained: its kernel drops further connects, so
//            a dial to it is never answered and ends by its own timeout
//   held     a socket bound and listening that the runner keeps, so a listen on its address fails with AddressInUse
//   refused  a port that was bound and then released: nothing listens, so a dial is refused
//   answers  a listener the kernel keeps completing connects for, so a dial made while the loop is draining still opens
import std;
import os;
import goose_io from "../../..";
import goose_io.conformance.suite;
import epoll from ".";

// The runner's own use of the loop's C layer: declared again here, because a program may name the symbols it links.
extern fn c_listen(v6: bool, ip: const u8[16]&, port: u16, reuseport: bool, backlog: i32) -> i32;
extern fn c_local_port(fd: i32) -> i32;
extern fn c_connect_start(v6: bool, ip: const u8[16]&, port: u16) -> i32;
extern fn c_close(fd: i32);

var fixture_keep: i32[16] = [-1; 16];
var fixture_kept: i64     = 0;

fn keep(fd: i32) { fixture_keep[fixture_kept] = fd; fixture_kept++; }

fn loopback() -> u8[16] {
    var ip: u8[16] = [0; 16];
    ip[0] = 127; ip[3] = 1;
    return ip;
}

// Binds 127.0.0.1:0 with the backlog and returns the address text of what it got, keeping the socket open.
fn make_listener(backlog: i32, text: u8[>..]&) -> i32 {   // appends the address text
    var ip = loopback();
    let fd = c_listen(false, ip, 0, false, backlog);
    if fd < 0 { print("the runner could not listen: ", -fd); exit(2); }
    format(text, "127.0.0.1:", c_local_port(fd));
    return fd;
}

fn main() {
    var part = 0;
    if arg_count() > 1 {
        var text: u8[>..] = [];
        arg(1, text);
        for c in text { if c >= '0' && c <= '9' { part = part * 10 + (c - '0'); } }
    }
    var group: u8[>..] = [];
    if arg_count() > 2 { arg(2, group); }

    // All four address texts live in one array: the suite is only allowed to call a loop that shrinks its own arrays when the views
    // it holds are of one array exactly (the language's aliasing rule), so the fixture is four slices of one.
    var texts: u8[>..] = [];

    // silent: fill the accept queue (a backlog of one holds two completed connections), then more connects are dropped
    let sfd = make_listener(1, texts);
    keep(sfd);
    let silent_end = texts.len;
    var ip = loopback();
    var port: u16 = c_local_port(sfd) as u16;
    for k in 6 { let c = c_connect_start(false, ip, port); if c >= 0 { keep(c); } }

    keep(make_listener(16, texts));
    let held_end = texts.len;

    keep(make_listener(1024, texts));
    let answers_end = texts.len;

    let rfd = make_listener(1, texts);
    c_close(rfd);

    var io = epoll::Loop { .. };
    io.limits.half_close_timeout_ms = 3000;
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    let fixture = goose_io_conformance::Fixture { silent: texts[..silent_end], held: texts[silent_end..held_end], refused: texts[answers_end..], answers: texts[held_end..answers_end], unix: "" };
    if group == "half-close" { exit(goose_io_conformance::conformance_half_close_part(io, fixture, part)); }
    if group == "sizing" { exit(goose_io_conformance::conformance_sizing_part(io, fixture, part)); }
    if group == "abort" { exit(goose_io_conformance::conformance_abort_part(io, fixture, part)); }
    if group == "inspection" { exit(goose_io_conformance::conformance_inspection_part(io, fixture, part)); }
    if group == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_core_part(io, fixture, part));
}
```

The network tests that need real peers (the example libraries, the limits, closing) are in `tests/net/`, run by `tests/net/run.sh`.

## Candidate event loops and libraries

These are candidates, not claims: today the in-memory event loop and the epoll event loop above exist, and `docs/event-loops/` maps the first
few in detail. They show how much one contract could unify. They are not equivalent integration targets: some are
whole event loops (libuv, libevent), some are lower-level interfaces an event loop would be built on (liburing), and
TLS libraries and QUIC engines would be layers over an event loop, not event loops of their own.

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

## Layering one event loop over another

An event loop may wrap another and present the same contract above it (*Event loops can be layered*): a TLS layer,
a compression layer, a metering layer. `tests/support/wrapper.goose` is a small one and shows the pattern. Over
the in-memory event loop it

- changes every byte on the way out (XOR with a key) and restores it on the way in, so the links of the wrapper
  see their own bytes while the event loop underneath carries something else;
- delays each link's `Opened` by one pass, holding back in order whatever the link gets meanwhile; and
- passes every other event, and every other operation, through unchanged.

`tests/conformance/run.sh --wrapped` runs every part of the suite against it, and `tests/examples/over_wrapper.sh`
runs the tests of the example libraries over it, with no change to the suite, to the event loop underneath, or to
either library. What the wrapper had to get right is what any layer has to:

- **Events are queued, never nested.** The wrapper decides what the application is to be given while it handles an event
  of the event loop beneath, and the `serve` block gives it, one at a time, after the handler of the event beneath
  has returned. An operation of the wrapper never calls the application.
- **A delayed `Opened` delays what follows it.** A link's `Data`, `Writable`, `PeerEof` and `Closed` wait, in
  order, behind its `Opened`. A link closed before its `Opened` was given gets only its `Closed`.
- **Choices made at `Opened` must be kept until `Opened` is given.** A library chooses what the peer's end of
  stream does (`set_keep_open_on_eof`) while it handles `Opened`. If `Opened` is delayed, the event loop beneath
  would act on its default first. The wrapper keeps every link beneath open on end of stream, remembers what the
  library chose, and when the end of stream comes closes the link with `PeerClosed` itself unless the library asked
  to keep it open. It reads the choice when it gives the event and not before, because the library makes it while
  handling one of the events given just before.
- **`PassEnd` is the wrapper's own.** It is given once after the pass's link events, and before the next `Tick`,
  also for a pass in which only events the wrapper released were given.
- **A scripted peer on the event loop beneath sees what is on the wire**, so a test that uses one goes through the
  wrapper's `peer_` functions, which change the bytes the other way.

## Which check proves which scenario

Every scenario of `specs/io-contract/spec.md` of the change `define-contract-v1` is in this table. A scenario
that describes event loop behaviour has at least one check in `conformance/`, named in the third column. A
scenario that no event loop call can show (that the package builds, that it pulls in nothing native, that a
library imports no event loop) names the build or inspection step that proves it. The last column is the fault of
the in-memory event loop (`set_fault`, in `memory.goose`) that makes the check fail: a check that passes while its
fault is on is a defect in the suite, and `tests/conformance/faults.sh` finds it.

The same rows, with the scenario texts, are in `tests/conformance/checks.tsv`; `tests/conformance/table_check.sh`
fails when this table, that file, the suite and the specification disagree.

<!-- scenarios:begin -->
| Requirement | Scenario | Proved by | Part | Fault that must make it fail |
|---|---|---|---|---|
| The contract package is pure Goose | The package checks cleanly | build: `goose check goose_io.goose` (`just check`) | - | - |
| The contract package is pure Goose | Nothing native is pulled in | inspection: the search commands of `tests/checks/purity.sh`, run by `tests/run_tests.sh` (task 7.2) | - | - |
| Three roles, one contract | A library compiles against two event loops unchanged | build: `tests/unit/library_example_test.goose` on the in-memory event loop and over the wrapper of `tests/support/wrapper.goose` (`tests/examples/over_wrapper.sh` runs the example library tests over it) | - | - |
| Three roles, one contract | A library imports no event loop | inspection: `tests/examples/imports_test.sh` lists the imports of `examples/`  | - | - |
| The contract exposes no operating-system primitives | A zone identifier is rejected | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| The contract exposes no operating-system primitives | An event loop without descriptors conforms | inspection: the in-memory event loop has no descriptors and passes `tests/conformance/run.sh` | - | - |
| The contract states its version | A library reads the version | build: `tests/unit/types_test.goose` reads `VERSION_MAJOR` and `VERSION_MINOR` | - | - |
| Links are generation-checked handles | A stale handle cannot reach a reused slot | check `handles_stale_reuse`, `handles_stale_reset`, `handles_stale_send_room`, `handles_stale_peer_address` | 0 | `StaleHandleAccepted`, `StaleHandleAccepted`, `StaleHandleAccepted`, `StaleHandleAccepted` |
| Links are generation-checked handles | The handle is still valid while Closed is handled | check `handles_valid_in_closed` | 0 | `ClosedHandleStaleEarly` |
| Links are generation-checked handles | An unset handle is recognisably invalid | check `handles_unset`, `handles_unset_reset`, `handles_unset_shutdown_write`, `handles_unset_sizing`, `handles_unset_inspection` | 0 | `UnsetHandleAccepted`, `UnsetHandleAccepted`, `UnsetHandleAccepted`, `UnsetLinkHasRoom`, `UnsetHandleAccepted` |
| Events are delivered to one handler, one at a time | A close does not re-enter the handler | check `events_not_reentrant` | 0 | none (see below) |
| Events are delivered to one handler, one at a time | A send that closes the link does not re-enter the handler | check `events_not_reentrant_after_reset` | 0 | none (see below) |
| Link events follow a fixed order | An accepted link | check `order_accepted_link` | 0 | `PeerCloseDropsData` |
| Link events follow a fixed order | A link that never opens | check `order_failed_dial` | 0 | `OpenedBeforeFailure` |
| Every link event names its owner | Two libraries share one loop | removed with the tag in 0.2; see *Scenarios added by the link-keyed state*, below | - | - |
| Every link event names its owner | The user value comes back | removed with the user value in 0.2 | - | - |
| Every link event names its owner | The user value survives an immediate dial failure | removed with the user value in 0.2: the `Closed` of a dial that fails at once carries the link `dial` returned | - | - |
| Listening | A connection is accepted | check `listen_accepts` | 0 | `OpenedWithoutListener` |
| Listening | The address is taken | check `listen_held_address` | 0 | `HeldIgnored` |
| Listening | A system-chosen port can be discovered | check `listen_port_zero` | 0 | `PortZeroReportsZero` |
| Listening | Stopping a listener keeps its links | check `listen_stop_keeps_links` | 0 | `StopListeningClosesLinks` |
| Listener handles are never reused | A stale listener handle cannot reach a newer listener | check `listener_handle_never_reused` | 0 | `ListenerHandleReused` |
| Listener handles are never reused | Handles run out and do not wrap | unit test: `tests/unit/memory_links_test.goose` (`listener_exhaustion`); for a socket event loop, its mapping document (group 6) | - | - |
| A link reports its peer's address | An accepted link names its peer | check `peer_address_names_peer` | 0 | `StalePeerAddress` |
| A link reports its peer's address | A dialled link names its target | check `peer_address_names_peer`, `peer_address_ipv6` | 0 | `StalePeerAddress`, `Ipv6Unsupported` |
| A link reports its peer's address | A closed link has no peer address | check `peer_address_names_peer` | 0 | `StalePeerAddress` |
| Dialling never blocks and always ends in one event | A successful dial | check `dial_succeeds` | 0 | `DialReturnsInvalid` |
| Dialling never blocks and always ends in one event | A refused dial | check `dial_refused` | 0 | `RefusedAsUnreachable` |
| Dialling never blocks and always ends in one event | A dial that times out | check `dial_times_out` | 0 | `TimeoutEarly` |
| Dialling never blocks and always ends in one event | A host name is rejected, not resolved | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| A failed dial says why | A malformed address or a host name | check `dial_bad_address` | 0 | `BadAddressAsRefused` |
| A failed dial says why | A dial that times out says so | check `dial_times_out` | 0 | `TimeoutEarly` |
| A failed dial says why | A refused dial | check `dial_refused` | 0 | `RefusedAsUnreachable` |
| A failed dial says why | An event loop out of links | unit test: `tests/unit/memory_links_test.goose` (`link_limit`); for a socket event loop, its mapping document (group 6) | - | - |
| A failed dial says why | A library handles every kind | test: `tests/examples/lineclient_test.goose` (task 5.3) | - | - |
| Received bytes are lent for the duration of the event | Bytes arrive as a slice | check `data_arrives_as_slices` | 0 | `DataCorrupted` |
| Received bytes are lent for the duration of the event | A slow handler holds one buffer | check `data_slice_stable_in_handler` | 0 | `SendClobbersLentBytes` |
| Sending is all or nothing | The caller reuses its memory at once | check `send_copies_at_once` | 0 | `SendDropsLastByte` |
| Sending is all or nothing | A small send is accepted | check `send_copies_at_once` | 0 | `SendDropsLastByte` |
| Sending is all or nothing | A send before the link opens | check `send_before_open`, `send2_refusals` | 0 | `SendBeforeOpenSent`, `SendBeforeOpenSent` |
| Sending is all or nothing | A send after close | check `send_after_close`, `send2_refusals` | 0 | `SendAfterCloseAccepted`, `SendBeforeOpenSent` |
| Two parts can be sent as one | A header and a body | check `send2_joins_parts` | 0 | `Send2SwapsParts` |
| Two parts can be sent as one | Neither part is taken when both do not fit | check `send2_all_or_nothing` | 0 | `Send2TakesFirstPart` |
| Send backpressure is explicit and bounded | An oversized send never fits | check `send2_refusals`, `send_too_large` | 0 | `SendBeforeOpenSent`, `TooLargeGivesWritable` |
| Send backpressure is explicit and bounded | A reader that never reads does not grow memory | check `send_is_bounded` | 0 | `NeverFull` |
| Send backpressure is explicit and bounded | No room on a link that cannot send | check `send_room_is_zero_when_closed` | 0 | `RoomWhenClosed` |
| Writable follows Full once | A full queue is reported and later reopened | check `writable_after_full` | 0 | `NoWritable` |
| Writable follows Full once | Several refusals share one Writable | check `writable_once_for_many_refusals` | 0 | `WritablePerRefusal` |
| Writable follows Full once | Writable means the refused send fits | check `writable_means_it_fits` | 0 | `WritableOnFirstByte` |
| Writable follows Full once | A later refusal gets its own Writable | check `writable_next_episode` | 0 | `OneWritableOnly` |
| Reading can be paused | Pause and resume | check `pause_and_resume_reading` | 0 | `PauseIgnored` |
| Closing | Close after a reply | check `close_after_reply` | 0 | `PeerCloseDropsData` |
| Closing | Nothing but Closed after close | check `close_leaves_only_closed` | 0 | `WritableAfterClose` |
| Closing | Cancelling a dial | check `close_cancels_a_dial` | 0 | `CancelledDialOpens` |
| Closing | Reset | check `reset_aborts_the_peer` | 0 | `ResetIsGraceful` |
| Close does not lose accepted bytes | Close with unread input | check `close_with_unread_input` | 0 | `CloseWithUnreadResets` |
| Close does not lose accepted bytes | A peer that never reads | check `close_when_peer_never_reads` | 0 | `ClosedNeverDelivered` |
| Peer end of stream and half-close | Default behaviour on peer end of stream | check `peer_eof_closes_by_default` | 0 | `EofIgnoresDefault` |
| Peer end of stream and half-close | Answering after the peer half-closes | check `half_close_then_answer`, `shutdown_write_ends_sending` | 0 | `PeerEofBeforeData`, `SendAfterShutdownAccepted` |
| Close reasons are portable | The peer resets the connection | check `reset_aborts_the_peer` | 0 | `ResetIsGraceful` |
| Close reasons are portable | A loop-specific reason reaches a portable library | unit test: `tests/unit/memory_close_test.goose` (`close_with_reason`) and `tests/examples/lineclient_test.goose` (task 5.3) | - | - |
| Time and ticks | Regular ticks | check `ticks_are_regular` | 0 | `TickEvery250` |
| Time and ticks | A deadline shorter than the tick period | check `tick_by_is_prompt` | 0 | `TickByIgnored` |
| Time and ticks | Two libraries with different deadlines | check `tick_by_two_deadlines` | 0 | `TickByKeepsLatest` |
| End-of-pass notification | Batching replies | check `pass_end_follows_link_events` | 0 | `NoPassEnd` |
| End-of-pass notification | PassEnd is last | check `pass_end_follows_link_events` | 0 | `NoPassEnd` |
| End-of-pass notification | An idle pass | check `pass_end_not_on_idle_pass` | 0 | `IdlePassEnd` |
| The application runs and stops the loop | Stop with nothing open | check `stop_with_nothing_open` | 0 | `StopWaitsForGrace` |
| The application runs and stops the loop | Stop with a link that stays open | check `stop_link_stays_open` | 1 | `ShutdownEarly` |
| The application runs and stops the loop | Libraries finish and the loop ends early | check `stop_libraries_finish` | 2 | `StopWaitsForGrace` |
| Draining is the same on every event loop | Listening while draining | check `listen_while_draining` | 3 | `ListenAfterStop` |
| Draining is the same on every event loop | Dialling while draining | check `dial_while_draining` | 4 | `DialFailsWhileDraining` |
| Draining is the same on every event loop | Stop called twice | check `stop_called_twice` | 5 | `StopLatestWins` |
| Event loops can be layered | A transforming wrapper conforms | conformance: every part through the wrapper of `tests/support/wrapper.goose` (`tests/conformance/run.sh --wrapped`) | - | - |
| Event loops can be layered | A library cannot tell | test: the example library tests over the wrapper (`tests/examples/over_wrapper.sh`) | - | - |
| Scope of the base contract | IPv6 is supported | check `ipv6_loopback` | 0 | `Ipv6Unsupported` |
| Scope of the base contract | An event loop without extras conforms | inspection: the loop of `tests/support/core_only.goose` supplies only the core and passes `tests/conformance/run.sh --core-only` | - | - |
<!-- scenarios:end -->

### Scenarios added by the hardening of the in-memory event loop

That change added the requirement *A refused send is always resolved* to the contract. Its scenarios are proved
as follows; the first needs an ordering an event loop's calls cannot make, so it is a test of the in-memory
event loop.

| Scenario | Proved by | Fault |
|---|---|---|
| The write side is shut while a Writable is owed | `tests/unit/memory_ordering_test.goose` and `tests/unit/memory_data_test.goose` (in-memory event loop) | (the tests fail when the fix is undone) |
| The write side is shut after a refusal | check `full_not_writable_after_shutdown_write` | `WritableAfterShutdown` |
| The peer closes while a send is refused | check `full_resolved_when_peer_closes` | `FullUnresolvedOnPeerClose` |
| The retry after the peer is gone | check `full_resolved_when_peer_closes` | `FullUnresolvedOnPeerClose` |

### Scenarios added by the core and the groups

The change that made the contract a core and five groups added these scenarios (the others it restated keep the
checks of the table above, now run by group). `tests/conformance/run.sh --core-only` runs the core of the suite on
`tests/support/core_only.goose`, a loop that supplies the core and nothing else.

| Scenario | Proved by |
|---|---|
| A loop that supplies only the core | `tests/conformance/run.sh --core-only`: every part of the core passes on the loop of `tests/support/core_only.goose` |
| A library uses an extra the loop lacks | `tests/unit/core_only_sizing_mustfail.goose` and `tests/examples/lineserver_core_only_mustfail.goose`: the build fails and names `send_room` and `set_keep_open_on_eof`; `tests/unit/stub_no_send2_mustfail.goose` names `send2` |
| An event the loop never delivers | the core-only loop delivers no `PeerEof`, and the line client's tests, which handle it, pass on it (`tests/examples/over_wrapper.sh`) |
| The core is enough for a client | `tests/examples/lineclient_test.goose` on the core-only loop, run by `tests/examples/over_wrapper.sh` |
| The core check, A group check | `tests/unit/groups_test.goose`, `tests/unit/incomplete_core_mustfail.goose`, `tests/unit/stub_sizing_mustfail.goose` |
| A library runs on two event loops unchanged | `tests/unit/library_example_test.goose`, `tests/examples/over_wrapper.sh` (the wrapper and the core-only loop) |
| A library imports no event loop | `tests/examples/imports_test.sh`; `tests/examples/needs_check.sh` holds each header to what its library calls |
| IPv6 is covered | check `peer_address_ipv6` and the core checks that listen on `[::1]` |
| An event loop without extras conforms to the core | as *A loop that supplies only the core* |
| Default behaviour on peer end of stream, Answering after the peer half-closes | checks `peer_eof_closes_by_default`, `half_close_then_answer`, `shutdown_write_ends_sending` (half-close group) |
| Batching replies, PassEnd is last, An idle pass | checks `pass_end_follows_link_events`, `pass_end_not_on_idle_pass` (batching group) |
| A loop without batching | the core-only loop does not give on the `PassEnd` of the loop beneath, and the core suite and the line client pass on it |
| A header and a body, Neither part is taken when both do not fit | checks `send2_joins_parts`, `send2_all_or_nothing` (sizing group) |
| No room on a link that cannot send | check `send_room_is_zero_when_closed` (sizing group) |
| Reset | check `reset_aborts_the_peer` (abort group) |
| An accepted link names its peer, A dialled link names its target, A closed link has no peer address | check `peer_address_names_peer` (inspection group) |

### Scenarios added by the unix group

The change that added the unix group (the address forms `unix:/path` and `unix:///path`) added these scenarios. The group's checks need
`Fixture.unix`, an absolute path at which the loop may create a socket, and run by their own entry point,
`conformance_unix_part`, against a loop that supplies the core and the group (`tests/conformance/run.sh --group unix`).

| Scenario | Proved by | Fault |
|---|---|---|
| A listener and a dial on a path | check `unix_listen_dial` (unix group) | `UnixListenerIgnored` |
| The path is held | check `unix_held_path` (unix group) | `UnixOverlapIgnored` |
| Nothing listens on the path | check `unix_nothing_listens` (unix group) | `UnixRefusedAsBadAddress` |
| No port | check `unix_no_port` (unix group) | `UnixPortInvented` |
| Malformed paths | check `unix_malformed_paths` (unix group) | `UnixRelativeAccepted` |
| The longest path | check `unix_longest_path` (unix group) | `UnixLongestRefused` |
| The URL spelling names the same path | check `unix_url_spelling` (unix group) | `UnixTripleSlashRefused` |
| A held path is held under either spelling | check `unix_alias_held` (unix group) | `UnixAliasNotHeld` |
| A loop without the group | `tests/unit/core_only_unix_test.goose` (the core-only loop) and `tests/unit/memory_unix_test.goose` (the in-memory loop configured with `unix_paths` off): `BadAddress` for `listen` and `dial`; the suite does not check it, since a loop that supplies the group accepts the text |
| No peer text | `tests/unit/memory_unix_test.goose`: `peer_address` is empty on both ends of a path link; no check of the suite can say so, since it needs the inspection group and the unix group |
| A scripted peer at a path, Paths conflict only when equal | `tests/unit/memory_unix_test.goose` |
| A check that reaches into another group | `tests/conformance/groups_check.sh` |
| A loop that does not supply the group | `tests/conformance/run.sh --core-only` runs no unix part |

### Scenarios added by the link-keyed state

The change that removed the tag and the user value from the events (`link-keyed-state`, contract 0.2) added these
scenarios. A library finds its state from the link of an event; the event loop passes nothing in.

| Scenario | Proved by | Fault |
|---|---|---|
| An accepted link names its listener | check `owner_listener_named` | `WrongListenerNamed` |
| A dial that fails at once is found by its link | check `owner_dial_found_by_link` | `DialClosedLost` |
| Slots are reused before new ones are issued, A reused slot has a new generation | check `slots_dense` | `SlotsNeverReused` |
| A slot is not reused while Closed is handled | check `slot_kept_during_closed` | `ClosedHandleStaleEarly` |
| No event inside the dial | check `dial_no_event_inside` | none (see below) |
| The bound is the loop's peak | `tests/unit/memory_links_test.goose` (slots) |  |
| A stale link finds nothing, A foreign link finds nothing, Growing does not move values, Dropping touches one entry, A dropped value is gone, A put over a stale entry replaces it | `tests/unit/link_map_test.goose`, one body of laws that any table with `put`, `find`, `has` and `drop` can be run through |  |
| One map for each loop | stated in `docs/libraries.md`; nothing to run |  |
| Two libraries share one loop, Another library's Closed is not handled, Two instances of one library on one loop, A dialled link's Opened does not replace its state | `tests/examples/lineserver_test.goose`, `tests/examples/gateway_test.goose` and `tests/examples/lineclient_test.goose`: a library reports an event of a link it does not own as not handled |  |
| An operation that was removed | `tests/unit/removed_set_user_mustfail.goose`, `tests/unit/removed_tag_mustfail.goose` |  |

### Scenarios added by the lifecycle guarantees

The change `lifecycle-guarantees` (contract 0.2) states the life of a link and of a loop: the states, the result of every
operation in each state, the keep-open window, the handles and the loop's own states. Its scenarios are proved here, as
each group of them lands.

| Scenario | Proved by | Fault |
|---|---|---|
| Handles in a long run are distinct, No issued link has generation 0 | check `handles_pair_unique`; the driver also records every handle in every part of every group's suite and fails the running check on a pair issued twice | `GenerationNotAdvanced` |
| A slot is not reused while its Closed is pending | check `handles_slot_held`; the driver fails the running check in every other part | `SlotFreedOnClose` |
| The invalid link is never issued | check `handles_unset` (and its group variants); `tests/unit/memory_links_test.goose` | `UnsetHandleAccepted` |
| The last generation retires the slot, A retired slot does not lower the link limit | `tests/unit/memory_links_test.goose` (`age_slot`); no check of the suite can age a slot | |
| A dialled link seen twice is one issuance, A loop that does not advance the generation fails, A loop that reuses a slot early fails | `tests/conformance/driver_test.goose` and the two faults above | |
| Sending has one result in each link state, A link is in one of five states: one link in each state, a dialled link moves through the states, the event loop ends a link the library sees as open | check `states_send` (and `states_sizing` for `send2` and `send_room`) | `SendBeforeOpenSent`; `RoomWhenClosed`, `SendBeforeOpenSent` |
| A Closed send result is final: the peer goes away, a refused send then a Closed result | checks `states_closed_is_final`, `states_closed_wakes_nothing` | `ClosedResultNotFinal`; `WritableAfterClosedResult` |
| Ending a link has one result in each link state: close twice, reset a dial in progress, reset after close | checks `states_close`, `states_reset` (abort group) | `SecondCloseClosesAgain`; `ResetDialOpens`, `ResetAfterCloseClosesAgain` |
| Sending on a write-shut link, shutdown before the link opens, close after shutdown, a Closed result concerns only sending | check `states_half_close` (half-close group) | `ShutdownBeforeOpenRemembered`, `ClosedResultEndsShutLink` |
| Pausing takes effect in every live state: pause before Opened | check `states_pause` | `PauseBeforeOpenIgnored` |
| Keep-open is configured no later than Opened: while dialling, while handling Opened, a late call has no effect, an end of stream before Opened is handled | check `states_keep_open` (half-close group) | `KeepOpenWhileDiallingIgnored`, `KeepOpenLateHonoured`, `EarlyEofActedOn` |
| Each operation says how it completes: pausing is complete when it returns, one Tick may answer several requests | check `states_completion` | `TickByIgnored` |
| A dialling link has no peer address, a closing link still names its peer, a closed link has no peer address | check `states_inspection` (inspection group) | `PeerAddressGoneOnClose` |
| Sending on a write-shut link (`send2`, `send_room`), `peer_address` while write-shut | `tests/unit/memory_data_test.goose`, `tests/unit/memory_links_test.goose`: the sizing and inspection suites cannot call `shutdown_write` | |
| The batching and unix groups | no link operation and no states check: batching has only an event, unix only address forms | |
| Setting up on the serving thread | inspection (task 4.7 of `lifecycle-guarantees`): `grep -rn "thread\|spawn" --include=*.goose examples tests conformance memory.goose` prints nothing, so `examples/gateway.goose`, `examples/echo/`, `examples/lineserver/`, `examples/lineclient/`, every root program under `tests/` (`tests/unit/`, `tests/examples/`, `tests/conformance/memory_conformance.goose`, `wrapped_conformance.goose`, `core_only_conformance.goose`) and every entry point of `conformance/suite.goose` construct their loop, set it up and call `serve` on one thread | |
| Listening and dialling before serve: no event is delivered before serve, and serve delivers Opened for both links | check `setup_before_serve` (the entry point listens and dials before it calls `serve`), `tests/unit/memory_loop_test.goose` | `SetupEventsDropped` |
| Operations after serve returns, Serve a second time | checks `finished_loop` (core, part 1), `finished_loop_sizing`, `finished_loop_inspection`: each runs after `serve` has returned (ids of 900 and more); the half-close and abort operations return nothing, so their cells are covered by `tests/unit/memory_loop_test.goose` and `tests/unit/wrapper_loop_test.goose` | `SendAfterFinishSent`, `FinishedDialIssues`, `SecondServeRuns`; `PeerAddressAfterFinish` |
| Close, then stop; Stop, then close during the grace period | check `grace_keeps_local` (core, part 6) | `ShutdownOverridesLocal` |

### What the lifecycle guarantees added

An event loop that conforms to contract 0.2 keeps these obligations, each shown above:

- **the reserved invalid link**: the default `Link` (generation 0) is the one invalid link, and no loop issues a link with generation 0;
- **retirement**: a slot whose generations are used up is retired and never issued again, so no slot and generation pair is issued twice;
- **slots held until `Closed`**: a slot is not issued again until the `Closed` of the link in it has been delivered (and, as the dense-slot rule says, every handler of it has returned);
- **the keep-open window**: `set_keep_open_on_eof` takes effect only while dialling or in the handler of `Opened`, and an end of stream seen earlier waits for that handler;
- **reading controls while dialling**: `pause_reading` takes effect on a link that is still dialling;
- **`Closed` is final**: after a `Closed` send result sending has ended, `send_room` is 0 and no `Writable` follows;
- **the finished loop**: after `serve` returns every operation does nothing, `dial` returns the invalid link, and a second `serve` returns at once;
- **`Local` over `Shutdown`**: a link the library closed ends with `Local`, even at the end of the grace period.

### What cannot be shown by a fault

`events_not_reentrant` (*A close does not re-enter the handler*), `events_not_reentrant_after_reset` (*A send that closes
the link does not re-enter the handler*, in the abort group) and `dial_no_event_inside` (*No event inside the dial*) have no fault in the in-memory event loop. An operation of a queue-based event loop has no handler to call, so
it cannot be made to deliver an event from inside itself. The check is the driver's own guard: every check runs
under a counter of handler nesting, and the check fails if an event arrives while another is being handled. The
guard is shown to work by `tests/conformance/reentry_test.goose`, which tells the driver that a handler is already
running. An event loop that delivers an event from inside an operation fails the suite at whichever check is running.

A few scenarios depend on a limit a socket event loop cannot be asked to reach (*Handles run out and do not wrap*,
*An event loop out of links*). They are tested on the in-memory event loop and, for a socket event loop, answered in its
mapping document under `docs/event-loops/`.

The unix group's checks share one loop, so each derives its own paths from `Fixture.unix` (a suffix of the check's number),
and the group's malformed-path check needs no file system. The loop creates and removes the socket file, and the suite
stops its listeners before it ends.

`dial_while_draining` is complete only when the fixture supplies an address that still answers after `stop`
(`Fixture.answers`): every listener of the loop has stopped by then, so no call can make one. Without it the check
proves that the dial still ends in exactly one event and does not extend the grace period.
