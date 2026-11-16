# Design

## Context

See `proposal.md` for motivation. The facts that shape the approach:

- **Nothing in goose-io is validated.** `goose check goose_io.goose` fails on v2026.4 (`reactor/epoll.goose:290`, invalid match-arm patterns). Only `shim/epoll.c` has been exercised, by a C smoke test.
- **tcprouter is the baseline.** `~/dev/cnamecloud/tcprouter` at `05995d1` (`main`) is the benchmarked engine. Its `integrate/goose-io` branch only rebinds three epoll wrappers and was never compiled; its `design/std-io-reactor` branch proposes a coroutine-based contract.
- **tcprouter's engine has three layers in one `Worker`:**
  - *Generic:* the loop (`engine.goose`), slots, generations and buffer pool (`conn.goose`), the handler path (`handler.goose`: `send`, `dial`, `close`, `reset`, `pause_reading`, `shutdown_write`, `send_room`, `want_pass_end`, event queue), control messages, drain and statistics (`messages.goose`), address parsing, and the C layer (`src/c_sys.c`).
  - *Forwarding:* `_pump`, `_pump_direction`, `_write_buffer`, readiness flags, the ready queue and the 64 KiB budget in `conn.goose`. Forwarded sockets are registered once, edge-triggered. Handler links are level-triggered with interest recomputed on state change.
  - *Proxy policy:* routes, SNI inspection, retry, policy hooks, tags, deadlines and fences.
- **skein already runs on the generic layer** for HTTP connections and for outbound links (`deferred.goose`, `upstream.goose`), so that layer is known to be sufficient for a server and a pipelined client pool without coroutines.
- **Goose constraints (v2026.4):** function values are compile-time only, so nothing can register a callback; `coro fn` is a design note, not a feature; threads share no memory; a root struct cannot be returned or hold a `slot_pool`; one package per repository root; `goose run` cannot link libc externs, so tests are built with `goose build`.
- **Verified by a spike during planning** (three scratch files, checked and run): contract types in one namespace, a provider root struct whose operations are found through a generic `Io` parameter, a client library generic over `Io`, and a `serve<X, F>` loop calling hooks on a generic extension with an empty default. One limit found: the extension type must live in a named namespace; hooks declared in the global namespace are not found.

## Goals / Non-Goals

**Goals:**

- A contract that an epoll loop and an io_uring loop can both provide at full speed, expressible in today's Goose.
- A reference epoll provider that is tcprouter's code, moved, so that a later tcprouter refactor changes where code lives and not what runs.
- Proof, before the tcprouter refactor starts, that both the handler path and a forwarding extension hold tcprouter's numbers.
- Tests that exist before the code they test, and that fail when the code is wrong.

**Non-Goals:**

- Changing any file in tcprouter, skein, goose-postgres, goose-http or goose-wing.
- Optimising beyond tcprouter's current numbers. Parity is the gate; improvements are later work.
- A readiness-style adapter for pull-shaped loops (goose-http, goose-wing). It can be added later on top of this contract and is noted under Open Questions.
- Portability beyond Linux for the reference provider.

## Decisions

### D1. The contract is events in, calls out

A provider delivers `Opened`, `Data`, `Writable`, `PeerEof`, `Closed`, `Tick` and `PassEnd`; a library calls `listen`, `dial`, `send`, `close`, `reset`, `shutdown_write`, `pause_reading`, `set_user`, `tick_by` and a few queries. Received bytes are a slice the provider lends for one event. A send is taken whole by the provider or refused.

Why: this is the shape both kinds of loop can provide natively. An epoll loop receives into a pooled buffer and lends it. An io_uring loop lends the kernel-selected buffer from a provided-buffer ring, and its sends complete asynchronously, which only works if the provider owns the bytes. It is also the shape tcprouter and skein already use.

Alternatives considered:

- *Readiness plus `try_read`/`try_write` into caller buffers* (what the repository has now). Natural on epoll, and what goose-http and goose-wing look like, but on io_uring it forces either poll-then-read (giving up the completion model) or an extra copy, and a synchronous partial write of caller memory cannot be a completion at all. It also puts a write queue in every library. Rejected as the base.
- *Both, as two layers.* A small readiness interface for existing pull-shaped loops plus a generic adapter up to the event contract. Sound, but not needed to make tcprouter ready, and it doubles the surface to validate. Deferred.
- *Coroutine wait/resume values* (tcprouter's `design/08-io-contract.md`). Depends on a language feature that does not exist. The event contract does not block it: a scheduler can resume a frame from these events later.

### D2. The contract is tcprouter's handler API with seven deliberate differences

| tcprouter today | Contract | Reason |
|---|---|---|
| `Conn` | `Link` | neutral name; same slot and generation layout |
| `send -> bool` | `send -> SendStatus` (`Sent`, `Full`, `TooLarge`, `NotOpen`, `Closed`) | a library must tell "wait for Writable" from "never" from "gone" |
| tag only in `Opened` | tag in every link event | lets an application route events to libraries with one `match`, replacing skein's bit-31 convention |
| listeners only from `Config` | `listen(address, tag)` | a server library must be portable too |
| `Tick` every 100 ms, internal dial deadline | plus `tick_by(at_ms)` | millisecond deadlines for clients without a timer table in the provider |
| `Opened` carries `sni` (253 bytes) | `Opened` carries link, tag, listener | SNI is tcprouter's; it stays reachable through tcprouter's own accessor |
| `CloseReason` with `Fenced`, `InspectTimeout`, `InvalidHello` | portable reasons plus `Provider { code }` | proxy reasons are not portable |

Everything else keeps tcprouter's semantics exactly: all-or-nothing sends, one `Writable` per refusal, one pending `Data` per link, `Closed` always last, dial failures as a single `Closed`, peer EOF closing by default with opt-in `PeerEof`, and `PassEnd` only after passes that delivered link events.

### D3. How it is written in Goose

Contract types are concrete and shared (`Link`, `Listener`, `Event`, `SendStatus`, `CloseReason`, `IoError`). Operations are ordinary functions whose first parameter is the provider's worker type, found by method syntax. A library is generic over the provider:

```goose
// in a client library; it imports only the contract
fn client_event<Io>(c: Client&, io: Io&, ev: goose_io::Event) -> bool {
    guard goose_io::tag_of(ev) == c.tag else { return false; }
    match ev {
        Data d => { c.feed(io, d.link, d.bytes); },
        Closed x => { c.lost(io, x.link, x.why); },
        _ => { },
    }
    return true;
}

// in the application: one block, a compile-time chain, no registration
w.serve() { w, ev => on_event(w, ev, http, db); };
fn on_event(w: goose_io::Worker&, ev: goose_io::Event, http: Http&, db: Client&) {
    if db.client_event(w, ev) { return; }
    http.server_event(w, ev);
}
```

`Tick` and `PassEnd` carry no tag; the application passes them to every library. The provider is chosen where the worker is declared, and nothing else in the program names it.

Alternative considered: a trait-like wrapper set (`io_send<Io>(io, ...)`) as the only entry point. Kept only where a wrapper adds a check or a default; plain method calls on the provider are the primary form, because every extra layer is one more thing the parity gate has to clear.

### D4. The reference provider is tcprouter's code, imported before it is changed

1. Copy the engine files from tcprouter `05995d1` into goose-io unmodified, with their tests, as one commit that only renames the namespace. That commit must build and pass the copied tests.
2. Separate generic from proxy code in small commits, each keeping the tests green.
3. Rename to contract names last.

This makes every behavioural change a reviewable diff against known-good code, and gives a bisectable history if a gate fails.

What moves and what does not:

| Moves into goose-io | Stays in tcprouter (re-attached through the seam later) |
|---|---|
| worker loop, batch of 256 events, message-then-deadline-then-events order | `Config` routes, targets, `match_route` |
| slot table, generations, packed event keys | SNI inspection, `MSG_PEEK`, `SO_RCVLOWAT` |
| buffer pool, waiting-reads queue | forward pump, readiness flags, wakeup budget |
| handler path, send queue, dial, half-close | retry, policy hooks, `forward()` |
| event queue, `PassEnd`, batching window | tags' deadlines, fences, `CloseTagged`, `SetAddr` |
| timeouts sweep, accept pause on exhaustion | proxy-specific close reasons and statistics |
| `spawn`, per-worker message pipes, drain, signal helper, statistics gathering | |
| address parsing, C socket and epoll layer | |

### D5. The extension seam

`serve<X, F>(w, x)` takes an extension `x` resolved at compile time; `serve<F>(w)` supplies an empty one. Hooks, each called exactly where tcprouter's proxy code is entered today:

| Hook | Called | Replaces in tcprouter |
|---|---|---|
| `on_accept(w, listener, fd) -> bool` | a socket was accepted; true means the extension took it | `_new_connection` routing and inspection |
| `on_event(w, slot, kind, mask)` | an event for a slot in an extension-owned state, or an extension-registered socket | the inspecting, connecting and forwarding arms of `_dispatch_event` |
| `on_ready(w, slot)` | a slot queued by the extension is run after the batch | `_run_ready` calling `_pump` |
| `allows(w, tag) -> bool` | before a dial opens, a send, and a flush | `_tag_allows` |
| `on_close(w, slot, reason)` | a slot is being closed | server-socket close, policy notification |
| `on_sweep(w, now)` | the 250 ms sweep | inspect and connect timeouts, deadline enforcement |
| `on_message(w, kind, body)` | a control message of a kind the engine does not own | `Deadline`, `CloseTagged`, `SetAddr`, `Policy` |
| `wait_limit(w, now) -> i64` | computing the loop's sleep | tag deadlines in `_wait_limit` and the batching window |

Engine facilities the extension may use: register and re-arm an additional socket under an extension event kind, take and return a pool buffer and get its slice, queue a slot for `on_ready`, close a slot with a provider-specific reason, post extension messages, and read the pass clock.

Per-slot extension state lives in the extension, in an array indexed by the engine's slot index. The engine slot keeps a `state` byte whose upper range belongs to the extension.

Why hooks on a generic parameter: it is the mechanism tcprouter already uses for its policy (`serve<P, F>`), it is monomorphised, and an empty hook compiles to nothing. Alternative considered: a generic slot payload (`Worker<S>`) so proxy fields sit in the engine's slot. It keeps one cache line pattern, but generic root structs are unverified and it couples the engine's layout to its extension. Held in reserve: the seam-proof benchmark in D11 decides whether it is needed.

### D6. Tags are generic; fences are not

A link's 16-bit tag is part of the contract as the owner key. What a tag *means* (a lease, a deadline) is tcprouter's, expressed through `allows`, `on_message` and `on_sweep`. With no extension, `allows` is constant true and disappears.

### D7. Timers

`Tick` at least every 100 ms plus `tick_by(at_ms)`. The engine generalises tcprouter's `_dial_due` ("the earliest connect deadline; the loop sleeps no longer than that") into one earliest-wake field shared by dial timeouts and `tick_by`. No timer table, no handles, nothing to cancel. Libraries keep their own deadlines; a small `Deadlines` helper in goose-io (a bounded min-heap of `(at_ms, id)`) is offered so they need not each write one.

Alternative considered: `after(ms) -> Timer` handles with cancellation, as in the current repository (4096 slots, linear scans). Rejected: a per-request timer in the provider is cost on the hot path that tcprouter does not pay today.

### D8. Clock and addresses

`now_ms` is `CLOCK_BOOTTIME` in milliseconds, read once per pass, as in tcprouter (it must keep counting through suspend for fence correctness). Addresses are numeric text, `"ip:port"` or `"[ipv6]:port"`, parsed by the provider. Both are unchanged from tcprouter so no conversion sits on any path.

### D9. Conformance is self-hosted; engine tests are external

- **Conformance suite:** Goose programs in which both ends of every link are on the provider under test (one side listens, the other dials, on the same worker). Peer misbehaviour is produced with contract calls (`reset`, `shutdown_write`, `pause_reading`). The few things a contract call cannot produce (a blackholed address, descriptor exhaustion) come from a small per-provider fixture. The same sources therefore run on any provider.
- **Fake provider:** an in-memory loopback network with a virtual clock. A dial is paired with a matching listener; bytes sent on one link become `Data` on its pair, subject to scripted stalls and failures. It validates its own scripts against the contract's ordering rules.
- **Engine tests:** tcprouter's Python network drivers and Goose harness servers for the generic layer, ported to the contract's names. They observe the wire from outside the process, so they catch errors a self-hosted suite would mirror on both ends.

Alternative considered: only external Python drivers. Rejected as the conformance mechanism because a fake provider and, later, non-Linux providers could not run them.

### D10. Performance gates and how they are measured

Baseline: tcprouter `05995d1`, `examples/http_hello.goose`, optimised build. Candidate: the same program on the goose-io engine.

1. **System calls per request** with `strace -c -f` over a fixed request count (tcprouter's `bench/syscalls.py`). Deterministic; must be equal for `recv`, `send`, `epoll_wait`, `epoll_ctl`, `accept4` and `close`.
2. **Throughput, p99, CPU per request** with `wrk`, one worker, pinned CPUs, host otherwise idle, rounds alternating baseline and candidate (A B A B ...), at least seven rounds each. The baseline's own min-to-max range over its rounds is the allowed spread; the candidate's median must fall inside it or better.
3. **Memory:** idle RSS, RSS with 10,000 idle links, and RSS under load (tcprouter's `bench/memory.py`), no worse than baseline.

A run where `wrk` or the backend was the limit is void. Results, host details and both commits are stored under `bench/results/`.

### D11. Seam proof before the change is accepted

A test extension under `bench/forward_ext/` carries a copy of tcprouter's forward pump with a fixed target and no routing, SNI, retry or policy. It is measured against tcprouter's `bench/forward_server` on the 11 B, 16 KiB and 64 KiB keep-alive workloads with the same two gates as D10. This is the evidence that tcprouter can be refactored onto goose-io without loss; if it fails, the seam is changed (first candidate: the generic slot payload from D5) before this change is accepted. If no seam design reaches parity, the recorded fallback is that tcprouter keeps its engine and provides the contract directly, and the reference provider remains for everyone else.

### D12. Layout

```
goose_io.goose              package entry
contract/                   types, tag_of and helpers, Deadlines        (pure Goose, no extern)
epoll/                      worker, links and pool, handler ops, control, address, sys, extension seam
fake/                       in-memory provider
shim/sys.c                  sockets, epoll, pipes, signals, clocks      (Linux-guarded)
examples/                   http_hello, lineclient (the example client library)
tests/unit/  tests/conformance/  tests/net/        run by tests/run_tests.sh
bench/                      syscalls, http bench, memory, forward_ext, results/
docs/                       contract.md, providers.md, extending.md
```

The existing `core/`, `reactor/`, `shim/epoll.c`, `tests/lit/` and `tests/native/` are deleted in the first implementation commit. One package and one namespace (`goose_io`), as tcprouter does, unless the first task shows a package can export several namespaces.

## Risks / Trade-offs

- **Separating generic from proxy code changes behaviour by accident** → import unmodified first (D4), port the tests before touching the code, keep each separation commit small and green.
- **The seam costs something on the forward path** (an extra array access per pump, a call that fails to inline) → measured in D11 before acceptance, with a named alternative and a named fallback.
- **Event shape changes move the numbers** (tag in every event, a different `Opened`) → the syscall gate is exact and the throughput gate uses the baseline's own spread; `Opened` becomes smaller, not larger.
- **A contract with one real provider is not yet proven portable** → the fake provider is a second, structurally different implementation; the contract ships as version 0 and the io_uring change is expected to be allowed to amend it.
- **A borrowed `Data` slice is safe today because the handler is a block.** Under future coroutines a slice passed as a resume value may outlive its buffer logically. → Not solved here; recorded as an open question for the coroutine integration.
- **Level-triggered handler links call `epoll_ctl` on state changes.** This is tcprouter's current behaviour and is preserved; improving it would break parity in the other direction and is later work.
- **Engine code moves from a private repository to goose-io** → the owner of both requested it; nothing proxy-specific (routes, SNI, policy, fences) is copied except the forward pump in `bench/forward_ext/`, which is flagged for the owner's review before any push.
- **Benchmarks need a quiet host and can be noisy** → alternating rounds, void rules, and the deterministic syscall gate as the primary signal.
- **Intermittent test failures** → a failure in any repetition is a failure until explained (tcprouter's rule, kept).

## Migration Plan

- No released consumer exists. tcprouter's `integrate/goose-io` branch pins commit `a58a8cdc`, which stays in history; that branch is superseded and should not be merged.
- The work lands on a branch of goose-io. `main` is updated only after all gates pass. Nothing is pushed or tagged without the owner's explicit approval.
- After acceptance, tag `v0.1.0` so tcprouter's refactor can pin it.
- Rollback is a revert of the merge; the old sketch remains in history.

## Open Questions

- Does importing only the contract module from the package avoid compiling `shim/sys.c` into a program that uses a different provider? It affects build size only, not behaviour.
- Should goose-io later offer the readiness adapter (D1, second alternative) so goose-http and goose-wing can provide the contract cheaply? Decide when one of them tries to adopt.
- How does a `Data` slice map onto a coroutine resume value once `coro fn` exists?
- Cross-thread messaging to a library (for example a resolver thread posting an address) is outside the base contract. The engine's control-message path could carry it as an optional capability; decide with the first library that needs it.
