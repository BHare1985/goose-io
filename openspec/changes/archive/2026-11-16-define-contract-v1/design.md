# Design

## Context

See `proposal.md` for motivation. The facts that shape the approach:

- **Nothing in goose-io is validated.** `goose check goose_io.goose` fails on v2026.4 (`reactor/epoll.goose:290`, invalid match-arm patterns). The contract it sketches is readiness-style (`WaitSet`, `try_read`, `try_write`).
- **The baseline for the contract's shape is tcprouter's handler API** (`~/dev/cnamecloud/tcprouter` at `05995d1`, `handler.goose` and `engine.goose`). skein runs an HTTP server and outbound client links on it, so that shape is known to carry a server and a pipelined client pool without coroutines, at benchmarked speed.
- **The attached analysis ("Std.io Contract Design Analysis") was a starting point and was not checked.** This design checked its claims against tcprouter's source, the Goose v2026.4 documentation, the upstream uSockets implementation, and the public headers of Bun's uSockets fork, libuv, libevent and liburing. What held and what did not is recorded in D3 and D9.
- **Goose constraints (v2026.4):** function values are compile-time only, so nothing can register a callback; `export fn` lets C call Goose but must be top-level and non-generic; there are no coroutines; threads share no memory; a root struct cannot be returned. A package is its directory, and a directory below the root with its own build sidecar is not part of the package (`docs/packages.md`), which is what lets example providers with C live in this repository without entering the contract package.
- **Verified earlier by a spike** (scratch files, checked and run): contract types in one namespace, a provider root struct whose operations are found by method syntax through a generic `Io` parameter, a client library generic over `Io`, and a `serve` loop that calls a compile-time block. One limit found: a type that supplies operations must live in a named namespace; functions in the global namespace are not found.

## Goals / Non-Goals

**Goals:**

- A contract precise enough that two people can write a provider and a library separately and have them work together.
- A contract that a readiness loop, a completion loop, a C-library-backed loop and an in-memory loop can each provide without changing what a library sees.
- Tests that fail when the code is wrong: a suite whose every check is shown to catch a fault.
- Zero native code in the contract package.

**Non-Goals:**

- Any socket-backed provider in this change. They are later example changes.
- Performance work or measurement. The contract keeps the shape that is already benchmarked; parity gates belong to the tcprouter-engine example change.
- Changing any file in tcprouter, skein, goose-postgres, goose-http, goose-wing or c_proxy.
- A readiness-style adapter for pull-shaped loops (goose-http, goose-wing).

## Decisions

### D1. goose-io is the contract package; providers are examples outside it

The package root holds only pure Goose: the contract, the in-memory provider, the conformance suite and a deadline helper. Socket-backed providers go under `examples/providers/<name>/`, each with its own build sidecar and C, so by Goose's package rule they are separate programs and nothing in the package can depend on them. When goose-io goes public each such directory moves to its own repository unchanged.

Alternative considered: keep a reference epoll engine inside the package (the superseded plan). Rejected for version 1: it ties the contract's release to an engine port and its parity gates, and it puts C in every importer's build.

### D2. The contract is events in, calls out

A provider delivers `Opened`, `Data`, `Writable`, `PeerEof`, `Closed`, `Tick` and `PassEnd`. A library calls operations. Received bytes are a slice the provider lends for one event. A send is taken whole by the provider or refused.

Why: an epoll loop receives into its own buffer and lends it; an io_uring loop lends the kernel-selected buffer and needs to own bytes it sends, because its sends complete later. A C library such as uSockets or libuv already pushes received bytes to a callback. All three can provide this shape; none can provide "readiness plus `try_read` into the caller's buffer" without giving something up.

Alternatives considered: readiness plus `try_read`/`try_write` (what the repository has; forces a copy or a poll-then-read on completion loops and puts a write queue in every library); protocol libraries with no I/O at all plus per-loop glue (works, but every client still needs glue for dial, reconnect, timers and backpressure per loop); coroutine wait/resume values (needs a language feature that does not exist; this contract does not block it).

### D3. What was taken from the attached analysis, and what was not

| Proposal in the analysis | Decision | Reason |
|---|---|---|
| `stop` to end the loop | **Adopted** as `stop(grace_ms)` plus `draining` | The suite and every program need a provider-neutral way to end `serve`. A grace period matches tcprouter's drain and lets servers finish replies. |
| `listener_port` | **Adopted** | Tests bind port zero and must learn the port. uSockets has `us_socket_local_port`. |
| `max_send` query with a floor | **Kept** (already planned), floor 4096 | tcprouter's limit is four pool buffers and the buffer size is configurable; a higher floor would exclude small configurations. |
| `dial` returns `Result`, no events on error | **Not adopted** | tcprouter returns a link always and reports every failure as one `Closed`. A library then has one failure path instead of two. |
| `user` passed to `dial` | **Not adopted** | `set_user` right after `dial` is equivalent because no event is delivered before the handler returns. A scenario now pins that an immediate failure still carries the value. |
| `user` widened to 64 bits | **Not adopted** | 32 bits index any table a no-heap library has; the library detects reuse by comparing its stored link with the event's. Link events stay at 32 bytes and match the baseline. |
| `sendv` (any number of parts) | **Adopted in a narrower form**, `send2(link, first, second)` | Research (D9) found a native two-or-more-part write in every substrate checked, and header-plus-body is the common case. Two parts avoid a slice-of-slices type whose Goose form is unproven. |
| `acquire_buf`/`send_buf`/`release_buf` | **Deferred** | A buffer handle that outlives a call is hard to express under Goose's borrowing rules and adds a leak path. The baseline does one copy into the provider's queue and is the benchmark. Can be added later without breaking libraries. See Open Questions. |
| (not in the analysis) peer address of a link | **Added** as `peer_address(link)` | Servers need it for logging, limits and access rules. Every substrate checked has it. tcprouter does not expose it today. |
| `ConnectTimeout`, `ProtocolError` reasons | **Not adopted** | A timed-out dial is `ConnectFailed`, as in tcprouter; since D13 it carries the kind `TimedOut`. A wrapper such as TLS uses the provider-specific reason. |
| Split of repositories (`goose-io`, `goose-io-usockets`, ...) | **Adopted as the end state**, staged per D1 | Matches the owner's direction: examples in this repository first. |
| "C callbacks can call straight into the Goose handler" | **False as stated** | `export fn` cannot be generic and the handler is a compile-time block. See D9. |
| `us_socket_pause` / `us_socket_resume` for `pause_reading` | **Not in upstream uSockets** | Only Bun's fork has them. Upstream needs `us_poll_change`. See D9. |
| "The uSockets contract with improvements" | **Not an accurate description** | The contract is tcprouter's handler API. It is stricter than uSockets in three places an adapter must make up. See D9. |

### D4. The contract surface

Types, all fixed-size values:

```goose
namespace goose_io;

struct Link     { slot: u32, gen: u32 }          // default value is invalid
struct Listener { id: u32 }                      // 0 is "none" (a dialled link); an id is never reused on a loop
enum SendStatus  { Sent, Full, TooLarge, NotOpen, Closed }
enum ConnectFailure { Refused, TimedOut, Unreachable, Denied, NoResources, BadAddress, Other }
enum CloseReason { PeerClosed, PeerReset, ConnectFailed { kind: ConnectFailure }, IdleTimeout, HalfCloseTimeout,
                   Local, Shutdown, Error, Provider { code: i32 } }
enum ListenErrorKind { None, AddressInUse, BadAddress, Denied, NoResources, Other }   // None: it did not fail
struct ListenError { kind: ListenErrorKind, code: i32 }
struct Address { text: u8[..56] }               // numeric text, empty when unknown

enum Event {
    Opened   { link: Link, tag: u16, user: u32, listener: Listener },
    Data     { link: Link, tag: u16, user: u32, bytes: const u8[:] },
    Writable { link: Link, tag: u16, user: u32 },
    PeerEof  { link: Link, tag: u16, user: u32 },
    Closed   { link: Link, tag: u16, user: u32, why: CloseReason },
    Tick     { now_ms: i64 },
    PassEnd  { },
}
```

Operations, each a function whose first parameter is the provider (`io`):

| Group | Operation | Result |
|---|---|---|
| Listening | `listen(address, tag)` | a `Listener` and a `ListenError` (two results; kind `None` on success) |
| | `listener_port(listener)` | `u16`, 0 for an unknown listener |
| | `stop_listening(listener)` | none; no effect on an unknown listener |
| Links | `dial(address, tag, connect_ms)` | `Link`, always valid |
| | `send(link, bytes)` | `SendStatus` |
| | `send2(link, first, second)` | `SendStatus`, both parts or neither |
| | `peer_address(link)` | numeric text, empty if not open |
| | `send_room(link)` | bytes a send would accept now |
| | `max_send()` | largest single send, at least 4096 |
| | `pause_reading(link, paused)` | none |
| | `set_keep_open_on_eof(link, keep)` | none |
| | `shutdown_write(link)` | none |
| | `close(link)`, `reset(link)` | none |
| | `set_user(link, user)`, `user(link)` | none; `u32` |
| Time | `now_ms()` | `i64` |
| | `tick_by(at_ms)` | none |
| Host | `serve() { io, ev => ... }` | returns when stopped |
| | `stop(grace_ms)` | none |
| | `draining()` | `bool` |

Helpers in the contract package, pure functions over the types: `is_valid(link)`, `same(a, b)`, `tag_of(ev)`, `is_link_event(ev)`, the version constants, and `Deadlines` (a bounded min-heap of `(at_ms, id)` so libraries need not each write one).

`peer_address` returns a fixed-size value (`struct Address { text: u8[..56] }`, long enough for a bracketed IPv6 address and port).

Every mutating operation on a stale or invalid link is a no-op; `send` returns `Closed`. Every operation except `serve` may be called from inside a handler and from the host before `serve`.

### D5. The host side

`serve` takes a block; `stop(grace_ms)` is callable from a handler. After `stop`: listeners stop at once, `draining()` is true, links keep working, and `serve` returns when the last link has closed or the grace period has passed, whichever is first. At the end of the grace period the provider closes what remains with reason `Shutdown` and delivers those `Closed` events before returning. A grace period of zero closes everything in the current pass.

Why in the contract: without it the conformance suite and the example program would each need provider-specific code to end the loop. Why a grace period and not two calls: it is exactly tcprouter's drain, and it gives libraries one rule ("on `draining`, finish and close").

Constructing and configuring a provider, starting several loops, and signals stay provider-specific. A provider's "request a stop from another thread or a signal" entry point is its own.

### D6. How the contract is expressed and enforced in Goose

Goose has no interface declaration, so the contract is: shared concrete types, plus operation names and signatures that a generic library calls by method syntax on an `Io` type parameter.

Two things make that checkable:

- **A compile-time shape check.** `goose_io::require_provider<Io>(io)` contains one call of every operation with the contract's argument and result types and is never executed. A provider's root program calls it once; a missing or mistyped operation is then a compile error at one known place and not deep inside some library.
- **The conformance suite** (D8) for behaviour.

A library is a struct plus functions generic over `Io`, with one event entry point that returns whether it handled the event:

```goose
fn client_event<Io>(c: Client&, io: Io&, ev: goose_io::Event) -> bool {
    if !goose_io::is_link_event(ev) { c.on_tick_or_pass_end(io, ev); return false; }
    if goose_io::tag_of(ev) != c.tag { return false; }
    match ev {
        Data d => { c.feed(io, d.link, d.user, d.bytes); },
        Closed x => { c.lost(io, x.user, x.why); },
        _ => { },
    }
    return true;
}

// the host: the only code that names a provider
io.serve() { io, ev => if !db.client_event(io, ev) { http.server_event(io, ev); } };
```

### D7. The in-memory provider

A loopback network inside one struct: fixed tables of links and listeners, each link with a bounded outbound queue. A `dial` to an address that has a listener on the same loop joins two links; bytes accepted by `send` on one become `Data` on the other when the receiver is not paused and the queue rules allow.

- **Scripted peers.** For tests of one library, the test adds a peer that is not a library: it accepts or refuses dials to an address, or connects to a listener, and performs timed steps (send these bytes, stop reading, resume, half-close, close, abort). The test reads back what the library sent to each peer.
- **Virtual clock.** `serve` delivers everything that is due, then moves the clock straight to the next due time: the next regular tick, the earliest `tick_by`, a dial deadline, a scripted step, or the end of a grace period. Nothing sleeps. A run that passes a configurable limit of virtual time fails the test, so a broken library cannot hang it.
- **Fault switches.** A set of named faults (`DataAfterClosed`, `SecondWritable`, `MissingClosed`, `PartialSend`, `EventInsideSend`, and one for each check in the suite). They exist only so the suite can be shown to fail (provider-conformance: "Every check is shown to fail on a broken provider").
- **Determinism.** No randomness, no host clock; the same test gives the same event sequence at the same times.

As built (tasks 3.1 to 3.7):

- A peer plays one connection. A step's delay counts from when the step before it finished, or from when the peer's link opened, whichever is later; delays from the start of the test would make a script depend on when the library happens to dial. Dials meet waiting peers in the order they were added, which is how a refusal followed by a successful reconnect is scripted.
- Bytes wait in the receiving end's buffer, so the bound on what a sender may send is the receiver's unread bytes. `Writable` is queued when room for the largest send refused since the last `Writable` has opened (D13).
- After `close` or `reset` the provider delivers nothing for the link but its `Closed`: no `Opened`, `Data`, `Writable` or `PeerEof`. The specification now requires it (D13).
- `provider_close(link, why)` closes a link with any reason, so a library can be tested against `IdleTimeout`, `Error` and `Provider { code }`. `stored_bytes`, `passes` and `hit_time_limit` are for checks after the run.
- A test that must fail is a `*_mustfail.goose` file whose first line names text it must print; `tests/run_tests.sh` passes it only when it exits non-zero and prints that text. Code quoted whole in a document is marked `<!-- source: path -->` and `tests/checks/docs.sh` fails when it differs from the file.
- The provider uses growable arrays and has no fixed table sizes. `max_links` and `link_buffer` are the bounds a library can observe.

Alternative considered: a peer-less fake that lets tests inject events directly. Rejected: a test could inject a sequence the contract forbids, and libraries would be tested against behaviour no provider has.

### D8. The conformance suite

- **Self-hosted.** Both ends of every link are on the provider under test: the suite listens and dials on the same loop, and produces peer behaviour with contract calls (`reset`, `shutdown_write`, `pause_reading`, not sending). It therefore runs unchanged on any provider.
- **A fixture for the two things calls cannot produce:** an address that never answers a connect, and an address already held. The in-memory provider scripts both; a socket provider's runner supplies them.
- **Checks are state machines.** With no coroutines, each check is a small struct with a step counter, advanced by the events it receives and failed by a deadline on the loop's clock. A driver runs them one after another inside a single `serve`.
- **Parts.** Only one `stop` can be observed per `serve`, and constructing a provider is provider-specific, so the suite is divided into numbered parts and the runner starts one process per part: part 0 is every check that does not need `stop` and ends with "stop with nothing open"; the remaining parts each cover one `stop` scenario.
- **Entry point.** `goose_io::conformance_part<Io>(io, fixture, part) -> i32` returns the number of failed checks and prints each failure with the check's name and the requirement it proves. A provider's root program is about ten lines.
- **Time bounds use the loop's clock**, so the same bounds hold on the virtual clock and on a real one.
- **Self-test.** A runner switches on each fault of the in-memory provider in turn and requires the matching check to fail.

### D9. Research: can real event loops provide this contract?

**Method.** Source was read at the revisions below. Nothing was built or run, so every row is "the call exists and its code or declaration reads as stated", not "an adapter has been shown to work".

| Substrate | What was read | Depth |
|---|---|---|
| tcprouter `05995d1` | `handler.goose`, `engine.goose`, `src/c_sys.c` | implementation |
| uSockets upstream `166a048` | `libusockets.h`, `socket.c`, `loop.c`, `context.c`, `bsd.c`, `eventing/epoll_kqueue.c` | implementation |
| Bun's uSockets fork, `main` 2026-11-16 | `libusockets.h` | declarations only |
| libuv `v1.x` 2026-11-16 | `uv.h` | declarations only |
| libevent `master` 2026-11-16 | `bufferevent.h`, `listener.h` | declarations only |
| io_uring (liburing `master`, c_proxy) | `io_uring.h` opcodes and flags; c_proxy's engine read earlier | declarations, one implementation |

Not examined: Windows IOCP and kqueue directly (only through libuv and uSockets), and any runtime behaviour.

**Mapping.** "Adapter" means the provider's own code must supply it on top of the substrate.

| Contract item | tcprouter | uSockets upstream | libuv | libevent bufferevent | io_uring |
|---|---|---|---|---|---|
| `listen`, `Opened` | listeners come from configuration; a call is new | `us_socket_context_listen`, `on_open` | `uv_listen`, `uv_accept` | `evconnlistener_new_bind` | multishot `ACCEPT` |
| `listener_port` | new | `us_socket_local_port` | `uv_tcp_getsockname` | not checked | `getsockname` |
| `dial`, failure as `Closed` | `dial` | `us_socket_context_connect`, `on_connect_error` | `uv_tcp_connect` | `bufferevent_socket_connect`, `BEV_EVENT_CONNECTED`/`ERROR` | `CONNECT` |
| `connect_ms` | present | adapter timer (`us_socket_timeout` is whole seconds) | adapter `uv_timer` | `bufferevent_set_timeouts` | `LINK_TIMEOUT` |
| `Data` lent for the event | pool buffer | one shared receive buffer, valid during `on_data` | adapter hands its buffer to `uv_alloc_cb`, lends it in `uv_read_cb` | input `evbuffer` in the read callback | provided-buffer ring, multishot `RECV` |
| `send`, bounded, all or nothing | present | adapter queue; `us_socket_write` writes part and returns a count | adapter bound; `uv_write` queues without limit (`uv_stream_get_write_queue_size`) | adapter bound; output `evbuffer` is unbounded | adapter copy, then `SEND` |
| `send2` | new: two appends, one flush | `us_socket_write2` | `uv_write` with two buffers | two `bufferevent_write` calls | `SENDMSG` |
| `Writable` | present | `on_writable` | write callback | write callback at the low watermark | send completion |
| `pause_reading` | present | no dedicated call; `us_poll_change` on the socket's poll | `uv_read_stop`, `uv_read_start` | `bufferevent_disable(EV_READ)` | do not re-arm the receive |
| `PeerEof`, `shutdown_write` | present | `on_end`, `us_socket_shutdown` (source notes the application must track the peer's end itself) | `UV_EOF`, `uv_shutdown` | `BEV_EVENT_EOF`; shutdown not checked | receive result 0, `SHUTDOWN` |
| `close` after flushing | present | adapter drains its queue first; `us_socket_close` closes at once | `uv_shutdown` then `uv_close` | free after the output drains | adapter |
| `reset` | `SO_LINGER` 0 then close | no call; adapter sets `SO_LINGER` on `us_socket_get_native_handle` | `uv_tcp_close_reset` | `SO_LINGER` on the descriptor | `SO_LINGER`, then `CLOSE` |
| `peer_address` | new | `us_socket_remote_address` | `uv_tcp_getpeername` | address given to the listener callback | address from `ACCEPT` |
| No event inside an operation | present (events are queued) | **violated**: `us_socket_close` calls `on_close` before it returns; adapter must defer | callbacks run from the loop | `BEV_OPT_DEFER_CALLBACKS` | inherent |
| `Tick`, `tick_by` | `Tick` present; `tick_by` generalises the dial-deadline wake | `us_create_timer`, `us_timer_set` | `uv_timer_start` | not checked | wait timeout |
| `PassEnd` | present | loop post callback | not checked | not checked | end of a completion batch |
| `stop` | drain with a deadline | no stop call; `us_loop_run` returns when no polls remain | `uv_stop` | not checked | own loop |

Bun's fork adds what upstream lacks: `us_socket_pause`/`us_socket_resume`, a connection-reset close code, `us_socket_writev`, and asynchronous name resolution.

**What this establishes.**

1. Every operation and event has a mapping in every substrate examined, and none needs the contract's meaning changed.
2. The contract is not uSockets' contract with a tweak. It is tcprouter's handler API, which is in the same family (events pushed to the consumer). It is stricter than every C library examined in three places: sends are bounded and all-or-nothing (uSockets writes part; libuv and libevent queue without limit), no event is delivered inside an operation (uSockets does), and a failed dial is a single `Closed`. Each is supplied by an adapter-held queue, deferral list or timer, and each is something tcprouter's engine already does.
3. C loop libraries share one unsolved problem: reaching the Goose handler. They call C function pointers; a Goose `export fn` cannot be generic; the host's handler is a compile-time block. The adapter must therefore collect events in C and return to Goose to deliver them. libuv can return after each iteration (`UV_RUN_ONCE`) and the adapter owns the read buffers, so no copy is forced. Upstream uSockets has no call that returns per iteration (only a post callback) and reuses one receive buffer for every socket in an iteration, so received bytes must be copied or the loop restructured. A loop written in Goose over a thin C layer (tcprouter, c_proxy) has neither problem.

**What the contract does not cover, found by looking at what client libraries need.** These decide whether "99%" is true in practice. All are additions above or beside the base contract, not changes to it.

| Need | Who has it | Position |
|---|---|---|
| Host-name resolution | uSockets (blocking `getaddrinfo` inside connect), Bun's fork (asynchronous), libuv (`uv_getaddrinfo`), libevent (`bufferevent_socket_connect_hostname`) | Not in the base contract. Real clients are configured with names, so this needs an answer before the first real client: a resolver library on the contract, or a cross-thread wake so a resolver thread can post a result. |
| TLS | inside uSockets and Bun; separate in libuv | A wrapping provider. The "Providers can be layered" requirement and its test in this change prove the layering works in Goose before anything depends on it. |
| Hosting existing C clients (libpq, hiredis, libcurl, c-ares) | They need "tell me when this descriptor is readable"; every readiness substrate offers it (`us_poll`, `uv_poll`, `POLL_ADD`) | Cannot be in the base contract (an in-memory or completion-only provider has no descriptors). A later optional capability. |
| Wake from another thread | `us_wakeup_loop`, `uv_async_send`, `MSG_RING`, tcprouter's message pipes | A later optional capability. |
| Unix sockets | uSockets, libuv | An address form (`unix:/path`) can be added without changing any operation. |
| Socket options | all | Provider configuration. Providers are advised to disable Nagle's algorithm, as tcprouter does. |
| Writing into received bytes in place (WebSocket unmasking, as uWebSockets does) | uSockets, io_uring buffers | `Data` lends read-only bytes. Can be relaxed later. |

### D10. Example libraries

`examples/lineserver/` and `examples/lineclient/` speak a newline-delimited request/reply protocol, small enough to read in one sitting and enough to exercise everything a real client needs: a pool of links, pipelining with replies matched in order, a per-request deadline through `Deadlines` and `tick_by`, reconnect with backoff, and `Full`/`Writable` handling. `examples/gateway.goose` runs a line server whose replies are fetched through the line client from a second line server on the same loop.

### D11. Layout

```
goose_io.goose        package entry: types, helpers, version, require_provider
deadlines.goose       Deadlines helper
memory.goose          the in-memory provider, its scripted peers and its named faults
conformance/          the suite: suite.goose (driver and entry point), support.goose (what checks share),
                        handles, net, data, close, time (the checks), selftest (checks of the driver)
examples/
  lineserver/  lineclient/  gateway.goose
  providers/            empty in this change; one directory per later example provider
tests/
  unit/                 types, helpers, Deadlines, in-memory provider
  examples/             library tests on the in-memory provider, and over the wrapper
  conformance/          runs every part against the in-memory provider and the wrapper, the fault self-test,
                        checks.tsv (check, part, requirement, scenarios, fault)
  support/              kit.goose (what tests share), wrapper.goose (a provider layered over another)
  checks/               scripts that check the repository: quoted code, purity, provider mappings, layout
  run_tests.sh          runs every unit, driver and example test and the purity check
docs/
  contract.md           the reference: types, operation table with preconditions and results,
                        link state diagram, ordering rules, versioning
  libraries.md          how to write a library
  providers.md          how to write a provider and run the suite
  providers/            one mapping per candidate provider
```

Namespaces (settled by task 1.3, a scratch package checked and run on v2026.4): a module inside the package may declare a namespace other than the package's, is still imported as `import goose_io.memory;`, and its functions are found by method syntax through a generic `Io` parameter. So the contract is `goose_io`, the deadline helper stays in `goose_io`, the in-memory provider is `goose_io_memory` and the suite is `goose_io_conformance`. A root file outside the package root (a test or an example) declares the package once with `import goose_io from "<relative path to the root>";`.

One limit found by the same task: the compiler offers no size query for a type that contains a slice (`bytes_of` rejects it), so the "`Event` is at most 32 bytes" check is made on a mirror struct with the same fields and the slice replaced by two 64-bit words.

### D12. Sequence after this change

1. `define-contract-v1` (this change): contract version 0.1.
2. An example provider. The tcprouter-engine example reuses the plan in the superseded `define-io-contract` (import unmodified, separate generic from proxy code, extension seam, parity gates). The uSockets example starts from the questions in D9.
3. An io_uring example from c_proxy.
4. tcprouter's own refactor, a separate project, once its engine example has passed both the suite and the parity gates.

5. Benchmarks once two providers pass the suite: what the contract costs over each provider's own interface, including `PassEnd` with several libraries at high event rates.

Each provider change may amend the contract while it is at major version zero, but only after showing that the backend cannot meet the requirement another way (D13).

### D13. Review of the contract after the in-memory provider

An outside review of the contract was checked point by point against the specification, `docs/contract.md` and the in-memory provider. Each point was either already specified and tested, a real gap, or a suggestion not taken.

| Point raised | Finding | What changed |
|---|---|---|
| `Listener` has no generation, so a stale handle could stop a newer listener | Real gap: nothing said ids are not reused | New requirement *Listener handles are never reused*. `Listener` stays `{ id: u32 }`: listeners are few, so "an id is never issued twice" gives the same protection as a slot and a generation with one field, and a provider with a fixed table can put a slot and a counter inside the id. The in-memory provider already behaved this way; now tested |
| 32-bit link generations can wrap; make them 64-bit or retire slots | Not taken | A wrong match needs a library to use a handle after its `Closed` (already a bug) at the one moment in 2^32 reuses of that slot when the generation is the same. Retiring slots would instead exhaust a busy server's table within a year or two. Widening `Link` to 16 bytes pushes `Data` past the 32-byte event. The bound is now stated in `docs/contract.md` |
| Threading and re-entrancy are undefined | Already specified (*Events are delivered to one handler, one at a time*) and tested | Added the missing sentence that operations are called only on the loop's thread, and a scenario for `close` |
| Events caused by an operation should be delivered in a later pass | Not taken | The contract requires "after the handler returns". Requiring a later pass adds latency and nothing a library can rely on |
| Does `Full` three times give one `Writable` or three? | The document said one; the specification's wording ("for that refusal") could be read either way | New requirement *Writable follows Full once*, by episode |
| `Writable` should mean only that some room is free | Not taken, and tightened the other way | With "some room", a library refused 2000 bytes is woken for every byte a slow peer reads. `Writable` now comes once every send refused in the episode would fit. Every provider knows the refused size and a send never exceeds `max_send`, so it can always be met. The in-memory provider used the last refused size; it now uses the largest |
| `Sent` must mean accepted, memory reusable, nothing accepted otherwise | Already specified | Added "not that the peer has received them" and a scenario for reusing the memory at once |
| The lifecycle table; a handle valid during `Closed` | Already specified and tested | The order is now a table in the document; scenario added for the handle during `Closed` |
| What exactly does `close` do | Real gap in three places | *Closing* now says: does not wait for the peer; nothing but `Closed` is delivered afterwards; sends return `Closed`. New scenarios *Close with unread input* and *Nothing but Closed after close*. The document compares `shutdown_write`, `close` and `reset` in one table and says when `Closed` is delivered |
| `want_pass_end(false)` from one library turns `PassEnd` off for another | Real flaw | `want_pass_end` is removed and `PassEnd` is always delivered. It costs one handler call per pass that had link events. A counted or subscribed switch would add state to every provider to save that call |
| `tick_by` with several libraries | Already specified (earliest kept, one-shot, ask again on every `Tick`) and tested with two libraries | none |
| Host names, DNS, `connect_ms`, zone identifiers, address format | Host names were already rejected by rule. Zone identifiers and the output form of IPv6 were not specified | Zone identifiers make an address malformed. `peer_address` writes IPv6 in lower case with `::` for the longest zero run |
| Graceful shutdown needs defined steps | Mostly specified. Not specified: `listen` and `dial` after `stop`, and `stop` called twice | New requirement *Draining is the same on every provider*. `listen` fails. `dial` still works, unlike the review's suggestion, because a proxy that is finishing a request may need a new upstream connection; the link is under the same grace period |
| `max_send` per link or per provider; `send_room` on links that cannot send | Not specified | One value for the loop. `send_room` is 0 before `Opened` and after `close`, `reset` or `shutdown_write` |
| `Provider` code not for control flow; `PeerEof` default; `stop_listening` keeps links | Already specified and tested | none |
| Classify `ConnectFailed` (refused, timed out, unreachable) | Taken, by the owner's decision | `ConnectFailed { kind: ConnectFailure }` with seven kinds and no error number. `Other` is always allowed. New requirement *A failed dial says why*; the in-memory provider reports each kind and `fail_dials` scripts the ones only a system can produce |
| A conformance suite | Already the second capability of this change (task group 4) | The new scenarios are picked up by task 4.1, which lists every scenario |

The owner then decided the three points left open:

- **`PassEnd` stays always on**, and is the last event of its pass: no link event and no `Tick` of that pass follows it. The in-memory provider delivered a due `Tick` after `PassEnd`; it now delivers it first. The cost of the extra call is to be measured when providers are benchmarked, not guessed at now.
- **`ConnectFailed` carries a kind now**, before any library matches on the reason.
- **`close` and unread input**: the requirement stays, split out as *Close does not lose accepted bytes*, and says what it does not promise: that the peer's application receives the bytes. Each provider mapping has to say how it meets it and what happens when the peer never reads.

Two wordings were tightened: `Writable` comes once each refused send would fit on its own, not all together; a link dialled while draining does not extend the grace period. Listener handles that run out make `listen` fail with `NoResources`.

The contract is otherwise frozen until real providers are tried against it. A requirement that is awkward for one backend is not weakened until it is shown that the backend cannot meet it by another implementation strategy.

## Risks / Trade-offs

- **The contract is exercised by one provider, written by the same hand as the suite** → the fault self-test proves each check can fail; the research in D9 checks the contract against five real substrates by reading their source; the version stays at zero until a socket provider passes.
- **A self-hosted suite can mirror a provider's mistake on both ends** (for example bytes corrupted the same way in both directions) → checks compare against bytes the suite generated, not bytes it received back; socket providers additionally keep their own external tests, as tcprouter does.
- **The in-memory provider becomes the de facto definition** → the specification is the definition; where the two differ the provider is wrong, and the suite is written from the specification's scenarios, not from the provider.
- **No zero-copy send in version 0** → every send costs one copy into the provider's queue, as in the benchmarked baseline. Accepted for now; see Open Questions.
- **The research in D9 read source and ran nothing** → each mapping becomes a document with its unverified rows listed, and each example-provider change must pass the suite before its row counts as proven.
- **A borrowed `Data` slice is safe because the handler is a block** → under future coroutines a slice held across a suspension would outlive its buffer. Not solved here.
- **Deleting the existing code** → it is in git history at `a58a8cd`, which tcprouter's superseded branch pins.
- **Two changes now define `io-contract`** → `define-io-contract` must not be applied or archived; it is to be reworked into the tcprouter-engine example change or removed, at the owner's choice.

## Migration Plan

- No released consumer exists. Work lands on a branch; `main` is updated only after every task's checks pass. Nothing is pushed or tagged without the owner's approval.
- After acceptance, tag `v0.1.0` so later example changes and early library authors can pin it.
- Rollback is a revert of the merge.

## Open Questions

- **Zero-copy sends and more than two parts.** Candidate: a block form in which the provider lends part of its send queue for the library to fill. Decide when a real provider shows the cost of the copy; it is an addition.
- **Name resolution.** A resolver library on the contract, or a wake from another thread (D9). Needed before the first real client; does not change the base contract.
- **Descriptor readiness as an optional capability**, so existing C clients can be hosted on providers that have descriptors (D9).
- **Can the uSockets example deliver received bytes without a copy?** Belongs to that change (D9).
- **Should a provider offer a wake from another thread** (for a resolver thread, for example)? Outside the base contract; decide with the first library that needs it.
- **A readiness adapter** so goose-http and goose-wing can provide the contract cheaply: decide when one of them adopts.
- **How a `Data` slice maps onto a coroutine resume value** once `coro fn` exists.
- **How does each real provider close without losing the reply?** *Closing* now requires that unread input does not cost the peer bytes already accepted. Each mapping in task group 6 has to say how its provider does it (finish sending, then discard input) and what limit it puts on a peer that never reads.
