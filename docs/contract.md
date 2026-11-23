# The goose-io contract

Version 0.4. The declarations are in [`goose_io.goose`](../goose_io.goose); this document is the meaning. The normative requirements, each with test scenarios, are in the OpenSpec capability `io-contract`. Requirement names from it are quoted in *italics* below so that every rule here can be traced to its tests.

**In plain words.** An *event loop* moves the bytes (epoll, io_uring, libuv, or the in-memory one used for tests). A
*library* speaks a protocol (a server, a client). The contract is the small set of operations and events between them,
so a library never names the loop under it and a loop never needs to know which libraries run on it. If you want to
*use* it, start with the echo server in [`libraries.md`](libraries.md); to *supply* it, start with
[`event-loops.md`](event-loops.md). This document is the full specification both of them follow.

## 1. Purpose and roles

Only one loop can own a thread. If every loop has its own way to dial, send and receive, every client library has to be written once per loop. This contract is the one way.

| Role | Does | Depends on |
|---|---|---|
| **Event loop** | Owns the thread and the sockets. Delivers events, performs operations. A real one is built on epoll, io_uring, libuv or uSockets; the in-memory one in this repository is built on nothing. | The contract, plus whatever it is built on. |
| **Library** | Handles events, calls operations. An HTTP server, a Postgres client. | The contract only. Never an event loop's own types. |
| **Application** | The program. Constructs an event loop, runs it, passes each event to its libraries. | The contract and one event loop. |

No role stores a callback, allocates from a heap, or calls through a function pointer (*Three roles: event loop, library, application*). The contract package is Goose source only and links nothing (*The contract package is pure Goose*). No file descriptor, socket address structure or poll mask crosses it (*The contract exposes no operating-system primitives*).

**A loop belongs to the thread that serves it** (*A loop is set up, serving, draining or finished*, *A loop belongs to the thread that serves it*). The contract is per loop. The application makes every call to a loop, the calls before `serve` included, on the thread that calls `serve`, and does not use one loop from two threads. Every event is delivered on that thread and every operation is called on it: from a handler, or by the application before `serve`. An event loop may bind itself to the thread of the first call made to it. Calling an operation from another thread is not supported, and the contract has no operation that crosses threads. A wake from another thread is outside the contract (section 11). A link or a listener is used only on the loop that created it. Starting several loops is the event loop's business.

**Who calls what.** A library calls the link operations only on its own links (the ones it dialled and the ones its own listeners accepted), and the listener operations only on its own listeners. `serve` and `stop` belong to the application. `tick_by` is shared by design (section 5). Nothing a library can call changes what another library sees.

## 2. A core and optional capabilities

(*The contract is a core and optional capabilities*, *The core is twelve operations and five events*, *Each capability is checked on its own*, *Each capability is named by its parts*)

An event loop has to supply **the core**: 12 operations and 5 events, enough for a client, and for a server that answers as the bytes arrive. A server that answers after the peer has finished sending needs the half-close capability (the line server does; the line client does not). Everything else is in one of eleven **capabilities** that an event loop may supply or leave out. A library uses what it needs and says so in its header; built against a loop that lacks something it calls, it fails to compile, and the error names the operation.

| | Operations | Events |
|---|---|---|
| **Core** | `listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `now_ms`, `tick_by`, `serve`, `stop`, `draining` | `Opened`, `Data`, `Writable`, `Closed`, `Tick` |
| **Half-close** | `shutdown_write`, `set_keep_open_on_eof` | `PeerEof` |
| **Sizing** | `send_room`, `send2` | |
| **Abort** | `reset` | |
| **Inspection** | `peer_address`, `stop_listening` | |
| **Batching** | | `PassEnd` |
| **Unix** | the address forms `unix:/path` and `unix:///path`; no operation | |
| **Relay** | `relay`, `relayed_bytes` | |
| **Peek** | `peek`, `wait_input`, `discard_input` | `Input` |
| **Revoke** | `discard_unsent`, `write_deadline` | |
| **Wake** | `waker`, `wake` | `Woken` |
| **Limits** | `set_limit` | `Expired` |

Each capability has a compile-time **declaration**: a loop that supplies relay defines `supplies_relay(io: Loop&) -> goose_io::Supplied` in its own namespace, and the contract answers `goose_io::Absent` for every loop that does not. A library or a wrapping loop asks `goose_io::has_relay(io)`. A library may use a capability only when the loop supplies it, branching at compile time on the answer's type, and say so in its header (`// Uses if supplied:`); the branch for a capability the loop lacks is never compiled (*A loop declares each capability it supplies*, *A declaration agrees with the operations*, *A library may use a capability optionally*, *A wrapping loop passes on what it declares*). `require_<capability>` requires the declaration as well as the operations.

A rule that belongs to a capability binds only an event loop that supplies the capability, and no rule of the core depends on a capability. A loop that supplies only the core conforms to the core, and a library that uses only the core runs on it unchanged.

`listener_port` and `pause_reading` are in the core although they look like extras: a suite that runs both ends of every link on one loop cannot otherwise reach a system-chosen port or make a peer that does not read.

**Checking at compile time.** The contract package has one check for the core, `require_core(io)`, and one for each capability that has operations: `require_half_close`, `require_sizing`, `require_abort` and `require_inspection`. Each names every operation of its part once, with the contract's types, and never runs. An event loop's root program calls the check of the core and of each capability it supplies, so that a missing or mistyped operation is an error at that one line. A library's test calls the checks for what the library's header says it needs. Batching has only an event, and unix only an address form, so neither has a check; the conformance suite shows that a loop delivers `PassEnd` as it must and takes a path as it must.

**What an event loop that lacks a capability does.** It never delivers that capability's events: without half-close there is no `PeerEof`, since nothing could ask for it, and without batching no `PassEnd`. Without unix, `unix:/path` and `unix:///path` are an address like any other it does not accept: `BadAddress`. A library's handling of an event its loop never delivers is simply never run.

## 3. Types

All are fixed-size values.

| Type | Shape | Meaning |
|---|---|---|
| `Link` | `{ slot: u32, gen: u32 }` | A connection. The default value (slot 0, generation 0) is the one invalid link of every event loop: no event loop issues a link with generation 0, and every operation treats generation 0 as a handle that was never issued (*The invalid link is reserved*). `is_valid(link)`, `same(a, b)`. |
| `Listener` | `{ id: u32 }` | A listening endpoint. The default value means "none". `is_listener(l)`, `same(a, b)`. An id is never given to a second listener of the same loop. |
| `Address` | `{ text: u8[..56] }` | A numeric endpoint as text. Empty when unknown. `is_empty(a)`. |
| `SendStatus` | `Sent`, `Full`, `TooLarge`, `NotOpen`, `Closed` | Result of `send` and `send2`. |
| `CloseReason` | `PeerClosed`, `PeerReset`, `ConnectFailed { kind }`, `IdleTimeout`, `HalfCloseTimeout`, `Local`, `Shutdown`, `Error`, `LoopSpecific { code }` | Why a link ended. `is_portable(why)`, `is_connect_failed(why)`. |
| `ConnectFailure` | `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress`, `Other` | Why a dial did not open. See section 4. |
| `ListenError` | `{ kind: ListenErrorKind, code: i32 }` with kind `None`, `AddressInUse`, `BadAddress`, `Denied`, `NoResources`, `Other` | Result of `listen`. `failed(e)`. |
| `Event` | see sections 4 and 6 | What the application's handler receives. At most 32 bytes. |

**Addresses** are numeric text: `ip:port` for IPv4 and `[ip]:port` for IPv6, the same on every event loop, with IPv6 as hexadecimal capabilities. An event loop may accept more text than that (`inet_pton` takes `::ffff:192.0.2.1`), and a portable library passes only this form; the in-memory event loop treats an IPv4 tail as malformed. An event loop never resolves a host name, so there is no lookup to block the loop or to count against `connect_ms`; a host name given to `dial` fails with `ConnectFailed`. An IPv6 zone identifier (`%eth0`) is not part of an address and makes it malformed. An event loop that supplies the unix capability (section 6) also takes `unix:/path` and its URL spelling `unix:///path`. Protocol URLs (`postgres://`, `redis://`, `mysql://`) are not addresses: a library resolves them to a path or a `host:port` before it calls `dial`, and text that is neither is `BadAddress`.

**Handles.** A link handle is valid from the `dial` or `Opened` that produced it until the handler of its `Closed` event returns; during that handler `peer_address` (where the loop supplies it) and `relayed_bytes` still work. After that it is stale and every operation on it does nothing. An event loop never issues a slot and generation pair it has issued before on the same loop: a slot whose generations are used up is retired, not wrapped (*A slot and generation pair is never issued twice*). A slot is also held until the `Closed` of the link in it has been delivered, even with a new generation (*A slot is held until its Closed is delivered*), so a slot names at most one link that has not ended. A library still drops a handle when it sees its `Closed`. A listener handle is never reused at all (*Listener handles are never reused*); a loop that has issued every handle it can fails `listen` with `NoResources` and never starts again from an old one.

**How an event finds its state** (*A link event is recognised by what the library holds*, *Slot numbers are dense*, *A slot is freed when its Closed has been handled*, *A link map finds state by link*). Nothing is attached to a link or a listener: an event carries its link, and a library keeps its own state keyed by that link. A dialled link is the one `dial` returned to the library; an accepted link is one whose `Opened` names a listener the library started (the library compares it with its own listeners); every later event is one whose link the library has state for. The library reports an event as handled only for a link it owns and as not handled for any other, so that the application can offer it to the next library; a library that does not know the link of a `Data`, `Writable`, `PeerEof` or `Closed` does none of its handling for it.

The contract package offers `LinkMap<T>` for this: a table keyed by link in which `put` stores a value for a link, `find` returns a reference to it (or nothing for a link that is invalid, stale, foreign or dropped), `has` asks, and `drop` empties one entry. It is a helper, not a requirement: a library may keep its state any other way. It is flat, one entry for each slot up to the highest the library has used, so its memory is **the event loop's peak slot count times the size of an entry**, not the library's own peak. The event loop makes that bound hold by one rule: slots are dense, a freed slot is given to a new link before a slot never used is, and a slot is freed only when every handler of its `Closed` has returned (so a slot number is below the greatest number of links valid at once on that loop). A map belongs to one event loop: two loops can issue equal slot and generation pairs. A library whose state is large (a connection with kilobytes of buffers) keeps its records in a compact table of its own and puts only an index in the map, as the example servers do (`LinkMap<Ref>`); `bench/README.md` has the measurements.

## 4. The core

Every operation is a function whose first parameter is the event loop, called by method syntax: `io.send(link, bytes)`. Every operation except `serve` may be called from inside a handler and by the application before `serve`.

An operation on a link whose handle is invalid or stale (its `Closed` has been delivered, or the slot now belongs to another link) has no effect and touches no other link (*Links are generation-checked handles*). The last column says what it returns in that case.

### Operations

| Operation | Result | Effect | Stale or unknown handle |
|---|---|---|---|
| `listen(address)` | `Listener, ListenError` | Starts accepting TCP connections. Each accepted connection produces `Opened` carrying this listener. On failure the listener is "none", the error says why, and no events follow. (*Listening*) | n/a |
| `listener_port(listener)` | `u16` | The bound port, including one the system chose for port 0. | 0 |
| `dial(address, connect_ms)` | `Link` | Starts an outbound connection and returns a valid link at once. Never blocks. `connect_ms` of 0 means the event loop's default. | n/a |
| `send(link, bytes)` | `SendStatus` | Takes every byte, or none. See below. | `Closed` |
| `max_send()` | `i64` | The largest single send this event loop can ever accept. At least 4096. One value for every link of the loop, and it does not change while the loop runs. | n/a |
| `pause_reading(link, paused)` | none | While paused, no `Data` is delivered and the event loop does not read, so the peer is held back. | no effect |
| `close(link)` | none | Sends what was accepted, then ends the connection cleanly. On a link that has not opened, cancels the dial. | no effect |
| `now_ms()` | `i64` | The loop's clock in milliseconds. Monotonic; never goes backwards. Not wall-clock time. | n/a |
| `tick_by(at_ms)` | none | Asks for a `Tick` at or after `at_ms`. An event loop keeps only the earliest outstanding request, and the first such `Tick` satisfies it, so a library asks again while handling a `Tick` if it still has a deadline. | n/a |
| `serve() { io, ev => ... }` | returns when stopped | Runs the loop on the calling thread and calls the block once per event. | n/a |
| `stop(grace_ms)` | none | Starts draining. See below. | n/a |
| `draining()` | `bool` | True once `stop` has been called. A library that sees it should finish and close its links. | n/a |

Whether two listeners on overlapping addresses (the wildcard and a specific address, or one address on both) may coexist on one loop is up to the event loop: a library does not depend on it, and does not listen twice on one port. The in-memory event loop refuses the second with `AddressInUse`.

### Events

The application supplies one handler. An event loop delivers every event of the loop to it, on the loop's thread, one at a time, and never from inside an operation: an event caused by a call made in a handler arrives after that handler returns (*Events are delivered to one handler, one at a time*).

| Event | Carries | When |
|---|---|---|
| `Opened` | link, listener | The link is open. `listener` is "none" for a dialled link. |
| `Data` | link, bytes | Bytes from the peer, in order. |
| `Writable` | link | One or more sends were refused with `Full` and each of them would now fit. Once, however many were refused. |
| `Closed` | link, why | The link is gone. |
| `Tick` | now_ms | At least every 100 ms of the loop's clock, and at or after a time asked for with `tick_by`. |

**Order for one link** (*Link events follow a fixed order*):

| Situation | What the handler sees |
|---|---|
| A dial that succeeds, or an accepted connection | `Opened` first, before any other event of the link |
| A dial that fails, or that the library closes before it opens | one `Closed`, and no `Opened` |
| Bytes from the peer | `Data`, in the order the bytes arrived |
| The link ends, for any reason | exactly one `Closed`, last |
| After `Closed` | nothing for that link, ever |
| After the library calls `close` (or `reset`) | nothing but that one `Closed` |

With half-close, the peer's end of stream may add one `PeerEof` after every `Data` (section 6).

**Ownership** (*A link event is recognised by what the library holds*, *A library claims only the events of links it owns*): every link event carries its link, and `Opened` the listener that accepted it. A library treats a link event for a link it does not own as not handled. `Tick` carries no link and is offered to every library, and so is `PassEnd` where the loop supplies batching.

**`Data` bytes are lent** (*Received bytes are lent for the duration of the event*): the slice belongs to the event loop and is valid only until the handler returns. A library copies what it must keep, for example the unfinished tail of a message. An event loop has at most one undelivered `Data` per link and reads no more from that link until the handler has returned.

### Sending and backpressure

(*Sending is all or nothing*, *Send backpressure is explicit and bounded*)

`send` takes every byte or none.

| Result | Meaning | What follows |
|---|---|---|
| `Sent` | Every byte was taken: the event loop is now responsible for them and the caller may reuse its memory at once. It does not mean the peer has received them. Bytes go out in the order sends were accepted, with no further call needed. | nothing |
| `Full` | Does not fit now. Nothing was taken. | One `Writable` once it would fit. |
| `TooLarge` | Larger than `max_send()`. Will never fit in one call. | Nothing. Send it in pieces. |
| `NotOpen` | The link has not opened yet. Nothing was queued. | Wait for `Opened`. |
| `Closed` | The link is closing, closed or write-shut, or the handle is stale. | nothing: sending on it has ended for good |

They are decided in this order: `Closed`, `NotOpen`, then a send of zero bytes on an open link returns `Sent`, then `TooLarge`, then `Full`.

An event loop bounds what it holds unsent for each link, so a peer that never reads cannot make memory grow. A library that wants to know how much a send would take now asks the sizing capability's `send_room`; with the core alone it sends, and on `Full` waits for `Writable`.

**`Writable`** (*Writable follows Full once*) works by episode, not by call:

1. The first `Full` on a link starts an episode. Further `Full` results during it add nothing.
2. The event loop delivers one `Writable` once each send refused during the episode would fit on its own, which is to say once the largest of them would. Not all of them together, and not the first free byte: a library that was refused 2000 bytes is not woken to find room for 100.
3. That ends the episode. The library retries; the send that was refused now returns `Sent`, unless the library itself has sent on the link in between. A `Full` after it starts a new episode with its own `Writable`.

A link that was never refused gets no `Writable`, and `TooLarge` never leads to one. The event carries no size.

**A `Closed` send result is final for sending** (*A Closed send result is final*). Once `send` or `send2` has returned `Closed`, every later send returns `Closed`, `send_room` is 0, and no `Writable` is delivered for the link. It means one of two things, and the library knows which from what it has called:

- If the library called none of `shutdown_write`, `close` and `reset` on the link, the event loop is ending the link (the peer reset it, a write failed, a limit passed) and its `Closed` event follows with no further call. A loop returns `Closed` only once it has started ending the link, never for a transient condition. A library can drop its send queue on any `Closed` result.
- If the library called `shutdown_write`, `Closed` means only that **sending** has ended. The link goes on receiving, possibly for a long time, so the library expects `Data` until the `Closed` event, and a `PeerEof` if it asked to keep the link open.

**A refused send is always resolved** (*A refused send is always resolved*). After `Full` the link gets one `Writable` or its `Closed`; it never stays open and silent. It gets no `Writable` once its sending has ended by `close` (or by `shutdown_write` or `reset`, where supplied), including one the event loop had already queued: nothing can fit again, so the event would be untrue. When the peer goes away while a send is refused, an event loop chooses between the two. One on sockets will usually see the reset and close the link. The in-memory event loop delivers `Writable` after the link's `PeerEof` (when the library asked to keep the link open), and the retry is accepted and lost and resets the link.

To hold a peer back in the other direction, a library calls `pause_reading(link, true)` (*Reading can be paused*). A proxy that gets `Full` from one link pauses reading on the other and resumes on `Writable`.

### The life of a link

```
 dial() ──► Dialling ──connect ok──► Open ──────────────────► Closed
                │                     │                         ▲
                │                     │                         │
                └── fails, times out, │                         │
                    or close() ───────┴── close, the peer, ─────┘
 accepted by a listener ───────────► Open     the event loop, or stop
```

**The states of a link** (*A link is in one of five states*). A library can tell the state of each of its links from the calls it made and the events it received. The event loop may have begun to end a link that the library still sees as open (the peer went away), which is why `send` on an open link may return `Closed`.

| State | Means |
|---|---|
| dialling | `dial` returned, no event yet |
| open | after `Opened` |
| write-shut | after `shutdown_write` on an open link |
| closing | after `close` or `reset`, before `Closed` |
| ended | after `Closed`, or a handle that was never issued (the invalid link included) |

**What each operation does in each state** (*Sending has one result in each link state*, *Ending a link has one result in each link state*, *Pausing takes effect in every live state*, *Keep-open is configured no later than Opened*, *A link reports its peer's address*):

| Operation | dialling | open | write-shut | closing | ended |
|---|---|---|---|---|---|
| `send`, `send2` | `NotOpen` | `Sent`, `Full` or `TooLarge`; `Closed` if the loop is ending it | `Closed` | `Closed` | `Closed` |
| `send_room` | 0 | the room | 0 | 0 | 0 |
| `close`, `reset` | abandon; one `Closed`, `Local`, no `Opened` | end; one `Closed`, `Local` | end; one `Closed`, `Local` | no effect, no second `Closed` | no effect |
| `shutdown_write` | no effect | ends sending | no effect | no effect | no effect |
| `pause_reading` | takes effect (no `Data` until resumed) | takes effect | takes effect | no effect | no effect |
| `set_keep_open_on_eof` | recorded | recorded only while handling `Opened` | no effect | no effect | no effect |
| `peer_address` | empty | the address | the address | the address | empty |

**How an operation completes** (*Each operation says how it completes*). Every operation takes its effect and gives its result when it returns. Only some have one later notification, and no other event reports an operation's result:

| Operation | Returns with | Later notification |
|---|---|---|
| `listen` | a listener, or an error (no event follows an error) | none of its own; each accepted connection is a new link's `Opened` |
| `dial` | a link (the invalid link on a finished loop) | one `Opened` or one `Closed` (none on a finished loop) |
| `send`, `send2` | a `SendStatus`; `Sent` means taken, not delivered | after `Full`: one `Writable` or the link's `Closed` |
| `close`, `reset` | nothing; effective at once (sends return `Closed`) | one `Closed`, reason `Local` |
| `shutdown_write` | nothing; effective at once | none of its own; the link's `Closed` comes when both sides are done |
| `pause_reading`, `set_keep_open_on_eof` | nothing; effective at once (keep-open: applied when `Opened` returns) | none |
| `tick_by` | nothing; the request is recorded | a `Tick` at or after the earliest outstanding request; one `Tick` may answer several calls |
| `stop` | nothing; draining begins at once | `serve` returns |
| `stop_listening` | nothing; no connection is accepted after it | none |

**Why a dial failed** (*A failed dial says why*). `ConnectFailed` carries a kind. An event loop translates what its system reports into one of these and never passes an error number through. `Other` is always an honest answer when it cannot tell.

| Kind | Means | An event loop reports it when |
|---|---|---|
| `Refused` | Nothing accepts connections at the address. | the system reports a refused connection |
| `TimedOut` | No answer in time. | `connect_ms` elapsed, or the system gave up waiting |
| `Unreachable` | No route to the address, its network or its machine. | the system reports it |
| `Denied` | The system does not allow the connection. | the system reports it |
| `NoResources` | Out of links, descriptors, ports or memory. | the event loop has no link left, or the system reports exhaustion |
| `BadAddress` | The text is not an address the loop accepts. | it is malformed, a host name, has a zone identifier, or is a `unix:` path on a loop without the unix capability |
| `Other` | Anything else. | no kind above fits, or the event loop cannot tell |

`BadAddress`, `TimedOut` on `connect_ms`, and `NoResources` for the event loop's own links are always exact, because the event loop decides them itself. The kind is for reporting and for choosing how to retry: a library has a rule for the kinds it cares about and treats every other kind as it treats `Other`.

**Dialling** (*Dialling never blocks and always ends in one event*): `dial` returns a valid link immediately. The outcome is `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed or a host name, the connection is refused or unreachable, the event loop is out of resources, or the connect time passes. `send` before `Opened` returns `NotOpen`. Every event of the link is delivered after the handler that called `dial` has returned, so a library that stored the link `dial` returned finds its state for the event, including the `Closed` of a dial that failed at once, which carries that same link. `dial` never returns an invalid link: an event loop that is out of link slots still returns a handle and reports the failure as that link's `Closed`.

**Closing** (*Closing*). `close` sends the bytes already accepted and then ends the connection cleanly, without waiting for the peer to finish. After it, `send` returns `Closed`, and the only event the link still gets is its one `Closed` with reason `Local`: no `Data` for bytes that had arrived, no `Writable` that was owed, no `PeerEof`. It is delivered after the handler that made the call has returned, when the event loop has finished with the connection, which may be later than the same pass if accepted bytes are still going out. `stop` counts such a link as still present, so `serve` does not return while a reply is on its way.

**What `close` promises about bytes already accepted** (*Close does not lose accepted bytes*). There are three moments, and the contract covers the first two:

1. `send` returned `Sent`: the event loop is responsible for the bytes.
2. The event loop has handed them to the transport. After `close` an event loop does this before it ends the connection, and input it has received but not delivered must not make it discard them. On some systems closing a socket that still has unread input aborts the connection and the peer loses bytes already sent to it; an event loop has to avoid that, for example by finishing its sending first and discarding the input afterwards.
3. The peer's application has received and processed them. Nothing here promises that. A protocol that needs to know has the peer say so.

An event loop may abandon accepted bytes after a limit of its own when the peer does not take them, so that a peer that never reads cannot hold a closed link for ever. The link's event is still its one `Closed` with reason `Local`.

**The peer's end of stream** (*Peer end of stream and half-close*). In the core the event loop sends what was accepted and closes the link with reason `PeerClosed` when the peer finishes sending. This suits request/reply protocols where the peer closing means it is done. A library that must go on sending after the peer's end of stream needs half-close (section 6).

**Close reasons** (*Close reasons are portable*):

| Reason | Meaning |
|---|---|
| `PeerClosed` | The peer finished cleanly, or both sides did. |
| `PeerReset` | The peer aborted. |
| `ConnectFailed { kind }` | A dial did not open. The kind says why. |
| `IdleTimeout`, `HalfCloseTimeout` | The event loop's own limits, if it has them. |
| `Local` | This side called `close` (or `reset`). |
| `Shutdown` | The loop stopped while the link was open. |
| `Error` | Any other failure. |
| `LoopSpecific { code }` | A reason only this event loop has. The code is for logs. |

An event loop may close a link on its own policy at any time. A portable library handles every reason and treats `LoopSpecific` as `Error`; it never branches on the code.

### Time

(*Time and ticks*)

`now_ms()` is the loop's clock. It is read once per pass, so it does not move during a handler.

A library keeps its own deadlines. It asks for a wake with `tick_by(at_ms)` and checks its deadlines on every `Tick`. The event loop keeps no timer table and there is nothing to cancel. `Deadlines` in `deadlines.goose` is a small bounded heap of `(at_ms, id)` for libraries that have many.

### Running and stopping

(*The application runs and stops the loop*, *Draining is the same on every event loop*, *A loop is set up, serving, draining or finished*, *A finished loop does nothing*, *The end of the grace period*)

**The four states of a loop.** A loop is **set up** until `serve` is called: operations work as they do while serving (a `listen` and a `dial` made now are ordinary), and the events they cause are delivered once `serve` runs, none before. It is **serving** until `stop`, **draining** from `stop` until `serve` returns, and **finished** afterwards.

**A finished loop does nothing.** Once `serve` has returned, every operation returns without blocking and without delivering an event. `dial` returns the invalid link (`is_valid` is false), issues no link and starts no connection: this is the one exception to *Dialling never blocks and always ends in one event*, so a library that may dial after `serve` could have returned checks `is_valid` on the link `dial` gave it. `send` and `send2` return `Closed`, `send_room` returns 0, `listen` fails with kind `Other`, `draining()` is true, `now_ms()` never goes backwards, and every other operation has no effect. A second `serve` returns at once and never calls its handler.

`serve` runs the loop on the calling thread. From the call to `stop(grace_ms)`:

1. Every listener stops at once, `draining()` is true, and `listen` fails.
2. Links keep working, and `dial` still works, so a library can finish work in hand. Events go on as before. A link dialled now ends with the same grace period; it does not extend it.
3. `serve` returns as soon as no link is left: none open, none dialling, none whose `Closed` is still to be delivered.
4. At the end of the grace period the event loop closes every link that is left with reason `Shutdown`, delivers those `Closed` events, and then `serve` returns. A grace period of 0 does this in the current pass.

**The end of the grace period promises no delivery.** The event loop may discard the bytes accepted on a link that is still there, including bytes already handed to the transport, and may end the connection gracefully or by abort; a library does not assume that those bytes reach the peer. A link on which the library called `close` or `reset` before the grace period ended, whether before or after `stop`, ends with reason `Local`, never `Shutdown`: `Shutdown` is only for a link nobody had closed.

Of several calls to `stop` the earliest end of grace stands. A loop whose `serve` has returned is finished and is not run again.

## 5. Time shared between libraries

`tick_by` is the one operation several libraries share: the event loop keeps the earliest request, and every library is offered every `Tick`, so a library that wants a later wake asks again on the `Tick` it gets.

## 6. The capabilities

Each capability is a small set of operations and events with rules that bind only a loop that supplies it.

### Half-close

A page for library authors: [capabilities/half-close.md](capabilities/half-close.md).

(*Peer end of stream and half-close*) Operations `set_keep_open_on_eof(link, keep)` and `shutdown_write(link)`, event `PeerEof`.

- By default, as in the core, the event loop sends what was accepted and closes the link with reason `PeerClosed` when the peer finishes.
- After `set_keep_open_on_eof(link, true)` the event loop delivers `PeerEof` once, after all `Data`, and keeps the link open for sending. The library ends it with `shutdown_write` or `close`.
- **The keep-open window** (*Keep-open is configured no later than Opened*): `set_keep_open_on_eof` is recorded when it is called on a dialling link or while the link's `Opened` is being handled, and the setting applies from the moment that handler returns. A call made later has no effect, whether or not the peer has finished. An event loop that observed the peer's end of stream before then acts on it only after the `Opened` handler has returned, as the setting says. A fixed window makes every loop answer the same way: without it the result would depend on when each loop notices the end of stream.
- `shutdown_write` ends this side's sending while still receiving: bytes already accepted are sent, the peer sees end of stream after them, `send` afterwards returns `Closed`, and `Data` and `PeerEof` still arrive. When both sides have finished, the link closes with reason `PeerClosed`.

| Operation | Result | Precondition | Stale handle |
|---|---|---|---|
| `set_keep_open_on_eof(link, keep)` | none | while the link is dialling or while its `Opened` is handled | no effect |
| `shutdown_write(link)` | none | link is open | no effect |

A line server that answers what it has read after the peer finished sending needs this capability.

### Sizing

A page for library authors: [capabilities/sizing.md](capabilities/sizing.md).

(*Send backpressure is explicit and bounded*, *Two parts can be sent as one*) Operations `send_room(link)` and `send2(link, first, second)`.

- `send_room` is the number of bytes a send would accept now, never more than `max_send()`, and 0 before `Opened`, after `close`, `reset` or `shutdown_write`, and for a stale handle.
- `send2` is one `send` of the two ranges joined: a header and a body, or a frame prefix and a payload. Its size for `Full`, `TooLarge` and `send_room` is the sum of the two lengths, and it never takes one part without the other.

| Operation | Result | Stale handle |
|---|---|---|
| `send_room(link)` | `i64` | 0 |
| `send2(link, first, second)` | `SendStatus` | `Closed` |

Without sizing a library joins the two parts itself into a buffer of its own, and learns that a send did not fit from `Full`.

### Abort

A page for library authors: [capabilities/abort.md](capabilities/abort.md).

(*Closing*) Operation `reset(link)`: closes at once and discards unsent bytes, so the peer sees an abort (`PeerReset`). After it `send` returns `Closed` and the link's only further event is its one `Closed` with reason `Local`. No wait for the peer.

| | `shutdown_write` (half-close) | `close` (core) | `reset` (abort) |
|---|---|---|---|
| Bytes already accepted | sent | sent | discarded |
| What the peer sees | end of stream after those bytes | end of stream after those bytes | an abort (`PeerReset`) |
| Receiving afterwards | goes on: `Data` and `PeerEof` still arrive | stops: nothing more is delivered | stops |
| Waits for the peer | yes: the link closes when the peer has finished too | no | no |
| `send` afterwards | `Closed` | `Closed` | `Closed` |
| The link's last event | `Closed` with `PeerClosed`, when both sides are done | `Closed` with `Local` | `Closed` with `Local` |

### Inspection

A page for library authors: [capabilities/inspection.md](capabilities/inspection.md).

(*A link reports its peer's address*, *Listening*) Operations `peer_address(link)` and `stop_listening(listener)`.

- `peer_address` is the remote endpoint as numeric text in the form `dial` accepts. It is the address of an open, write-shut or closing link, available from the link's `Opened` until its `Closed` has been delivered, and empty for a dialling link, for a link whose `Closed` has been delivered, and for a stale or invalid handle. IPv6 is written in lower case with the longest run of two or more zero capabilities as `::`.
- `stop_listening` accepts no new connections on that listener. Links already accepted stay open, and the handle is never given to a later listener.

| Operation | Result | Stale or unknown handle |
|---|---|---|
| `peer_address(link)` | `Address` | empty |
| `stop_listening(listener)` | none | no effect |

### Batching

A page for library authors: [capabilities/batching.md](capabilities/batching.md).

(*End-of-pass notification*) Event `PassEnd`, no operation. It is the last event of every pass that delivered at least one link event; it lets a library batch: handle ten requests, then send ten replies at once. It is never delivered for a pass that delivered only a `Tick` or nothing. Calls made while handling it behave as anywhere else; the events they cause do not produce a second `PassEnd` for the same pass. It is the last event of its pass: no link event and no `Tick` of that pass comes after it, so what a library sends while handling it covers everything the pass did. It is always delivered by a loop that supplies the capability: there is nothing to ask for and nothing to turn off, so one library cannot take it away from another. The application offers it to every library once; a library that does not batch ignores it.

### Unix

A page for library authors: [capabilities/unix.md](capabilities/unix.md).

(*The unix capability is the address form unix:/path*, *A Unix socket path is absolute and bounded*, *unix:///path is a spelling of unix:/path*, *A Unix path is held by one listener and has no port*, *A Unix link has no peer address text*)

An event loop that supplies this capability accepts `unix:/path`, or `unix:///path` for the same path, wherever it accepts a numeric address, in `listen` and in `dial`, for a connection-oriented stream socket at that path. It adds no operation, event or type: the operations, events, results and rules are those of the core, so a library changes only the string it passes. A loop without the capability answers `BadAddress`, as for any text it does not accept, which a library already handles.

- **The path** is absolute, at most 103 bytes (the smallest limit among the common systems, less the terminator), with no NUL byte and no leading `@`. An abstract name, a relative path and an empty path are malformed, and so is `unix:` alone. The limit is on the path after the prefix. In the URL spelling the path follows `unix://` and begins with a single `/`: an authority (`unix://host/x`, `unix://x`) and a doubled slash (`unix:////x`) are malformed, and nothing is decoded or split, so `%`, `?` and `#` are bytes of the path. A loop does not resolve or normalise a path: `unix:/a/../b` is the path as written, and `unix:/a` and `unix:///a` are one endpoint. The failures the system reports for a well-formed path use the kinds the contract already has (`Refused`, `Denied`, `NoResources`, `Other`); the capability adds none. A system whose limit is smaller than 103 reports `BadAddress` for a path over its own.
- **A path is held by one listener.** A second `listen` on a path an active listener holds gives `AddressInUse`; the path is free again once its listener is stopped. A path never conflicts with a numeric address. A dial to a path nothing listens on ends with `ConnectFailed` of kind `Refused`, whether the system reports a missing file or a refusal.
- **No port.** `listener_port` returns 0 for a listener on a path.
- **No peer text.** `peer_address` returns the empty value for a link made on a path, since `Address` holds at most 56 bytes and the peer of an accepted connection has no name. The rule binds a loop that supplies both this capability and the inspection capability.
- **The file** is the loop's: it creates and removes it as its system requires, and the contract says nothing of permissions.

Abstract-namespace sockets, other socket types, the peer's credentials and passing descriptors are not part of the capability.

### Relay

A page for library authors: [capabilities/relay.md](capabilities/relay.md).

Operations `relay(a, b)` and `relayed_bytes(link)`. `relay` joins two open links: the loop carries the bytes of each to the other and the library sees none of them. It states the intent and not the mechanism: a loop may use buffers and a pump, `splice` or anything else, and one that copies conforms.

`relay` returns a `RelayStatus`. Only `Started` joins the links; the others change nothing: `NotOpen` (a link is dialling), `Closed` (a link is closing, closed or stale), `AlreadyRelayed` (a link is joined already).

A relayed link is in a sixth state, between open and closing. In it:

| Operation | Relayed link |
|---|---|
| `send`, `send2`, `send_room` | `Closed`, 0: the relay owns the sending of the link, as `Closed` after `shutdown_write` |
| `pause_reading`, `set_keep_open_on_eof`, `shutdown_write` | no effect |
| `close`, `reset` | end both links of the pair, each with one `Closed` of reason `Local` |
| `peer_address` | the address, as when open |
| `relayed_bytes` | the bytes carried from this link to its partner; 0 for a link never relayed or stale. Like `peer_address` it still answers while the link's `Closed` is handled, so a library reads its final count there |

A relayed link delivers no `Data` and no `Writable`. The pair ends as one. When both streams have ended, each link gets `Closed` with `PeerClosed`. When the pair fails, the link where it happened carries the true cause: `PeerReset` for its own peer's reset, `Error` for any other failure, `Local` for a limit of the loop's own (the stall limit on a peer that never reads); the partner gets `Error` after a reset or an error, and `Local` after a limit of the loop; the partner never gets `PeerReset`. Backpressure is the loop's: it stops reading a link while its partner cannot take more, so a pair holds at most one buffer of the loop's in each direction. Bytes held by `peek` when the library relays are the first bytes carried.

### Peek

A page for library authors: [capabilities/peek.md](capabilities/peek.md).

Operations `peek(link)`, `wait_input(link, n)` and `discard_input(link, n)`, event `Input { link, available }`. For a library that has to look before it chooses, such as one that picks a handler from the first bytes of a connection.

- `peek` returns the bytes that have arrived on an open link and have not been delivered as `Data`, valid until the handler returns, and consumes nothing: calling it twice shows the same bytes. It returns none for a link that is not open or is stale.
- `wait_input(link, n)` with `n` above 0 withholds `Data` and delivers one `Input` when `n` bytes have arrived, or the peer's stream has ended, or the loop's bound has been reached. `Data` stays withheld until `wait_input(link, 0)`, which delivers the held bytes unchanged and in order as `Data`.
- `discard_input(link, n)` drops the first `n` held bytes of an open link that is not relayed, at most as many as `peek` shows, and returns how many it dropped (0 for any other link). It delivers no `Input` and no `Data`; the rest stays held, in order. A library that has sent the held bytes on itself, such as a router replaying a hello to a second server, drops them so that `relay` does not carry them again.
- `Input` carries a count and not the bytes: they stay with the loop until `peek` or `relay`, so a library that decides without looking pays no copy.
- **The bound** is configuration that every loop exposes, with a documented default. At the bound the loop stops reading the link and delivers `Input` with `available` equal to the bound even when `n` is larger; the library then closes, relays, or calls `wait_input(link, 0)`. Nothing past the bound is read.
- A paused link holds its bytes and delivers no `Input` until it is resumed. The peer's end of stream is reported (`PeerEof` or `Closed`) after the released `Data`.

### Revoke

A page for library authors: [capabilities/revoke.md](capabilities/revoke.md).

Operations `discard_unsent(link)` and `write_deadline(link, at_ms)`. For a library whose fences say that no byte is written after a time.

- `discard_unsent` drops every byte the loop accepted on the link and has not handed to the transport, returns how many it dropped, and treats a `Writable` owed to the link as if those bytes had been sent. Bytes already handed to the transport are not recalled; a loop that cannot recall says so.
- `write_deadline` sets a time (`now_ms` clock; 0 removes it, a later call replaces it). From the moment the clock is at or after it the loop writes no further byte on the link, answers `send` with `Closed`, and ends the link with reason `Local`. The clock is read at each write and not taken from the start of the pass, so a process stopped between the start of a pass and a write does not write late. On a relayed link the deadline binds the relay's writes in both directions.

### Wake

A page for library authors: [capabilities/wake.md](capabilities/wake.md).

Operations `waker()`, `wake(waker, value)` and `wake_with(waker, value, body)`, event `Woken { value, body }`. `body` is up to 64 bytes (longer text is cut), empty for a plain `wake`; it is for a library whose messages carry data (for example a tag, a deadline or an address to change). `waker()` returns a `Waker`, a fixed-size handle that may be copied to any thread. `wake` is the only operation callable from another thread: the contract says that a loop belongs to the thread that serves it, and this capability is its one exception. Each `wake` delivers one `Woken` to the loop's thread, in the order one calling thread made them (there is no order between threads). `Woken` goes to every library like `Tick`; the application decides who handles it.

### Limits

A page for library authors: [capabilities/limits.md](capabilities/limits.md).

Operation `set_limit(link, kind, ms)`, event `Expired { link, limit }`. The loop reports when a link has been in a state for too long, and the library decides what to do. A loop alone can see these states once a relay carries the bytes.

| `Limit` | Expires when, for `ms` |
|---|---|
| `Idle` | no byte was read from or written to the link; a byte a relay carries counts for both links, and so does a byte the transport accepts while a queue drains |
| `Silent` | no byte was read (from the opening if none), whatever the library sends |
| `Stalled` | bytes wait to be sent on the link (or a relay holds bytes from its partner) and the transport accepts none; it runs only while something waits |
| `HalfOpen` | after the peer's stream ended on a link that stays open (kept open, or relayed), whatever crosses since |
| `Age` | after the link opened, whatever happens |

- `ms` 0 turns a kind off; a second call for a kind replaces it; kinds are independent.
- `Expired` is delivered once for each arming, in the first pass that begins at or after the due time (the loop sleeps until it is due and does not wait for the next `Tick`). Activity in a pass moves the due time of its link before limits are checked.
- The loop does not close the link: the library closes (and chooses the reason it records) or arms again. A close of one link of a relayed pair ends both.
- The loop never delivers `Expired` for a link after its `Closed`. A loop may use a clock that keeps counting while the machine is suspended; the contract does not require it.

A library's own deadlines (a connect timeout, a table of fences, a drain deadline) need no capability: `tick_by` and `Tick` give them.

## 7. Layering

(*Event loops can be layered*)

An event loop may wrap another: TLS, compression, a recorder. The wrapper presents this same contract upward, supplying the capabilities it passes through, and may delay `Opened` (a handshake), change the size of what is sent or received, and close a link with a loop-specific reason. Nothing in the contract lets a library tell a wrapped link from a plain one.

## 8. Scope

(*What the contract covers*)

The contract covers TCP byte streams over IPv4 and IPv6, stream sockets at a path in the unix capability, ticks and deadlines, and running and stopping one loop, and nothing else. An event loop that implements exactly the core conforms to it; nothing in a capability is required of an event loop that does not supply the capability.

## 9. Versioning

(*The contract states its version*)

`goose_io::VERSION_MAJOR` and `goose_io::VERSION_MINOR`. While the major number is 0, a minor increase may change or remove behaviour. From major version 1, a minor increase only adds. An event loop states the contract version it conforms to, the core and the capabilities it supplies.

The version of this document is **0.3** (`VERSION_MAJOR` 0, `VERSION_MINOR` 3 in `goose_io.goose`). Version 0.3 adds the capabilities relay, peek, revoke, wake and limits, the types `RelayStatus`, `Waker` and `Limit`, and the events `Input`, `Woken` and `Expired`; code that matches on every `Event` must name the new ones. Version 0.1 was the first release and is the version on `main`; 0.2 is the next one and adds the unix capability, removes the tag and the user value from the events and the operations (`set_user`, `user`) and the tag from `listen` and `dial`, adds `LinkMap` and the rule that slots are dense, and states the life of a link and of a loop (the link states and the result of each operation in each, the invalid link, retirement of an exhausted slot, slots held until `Closed`, the finished loop and the end of the grace period). The keep-open window is a tightening: a `set_keep_open_on_eof` call made after the link's `Opened` handler has returned, which 0.1 allowed while the peer had not yet finished, has no effect, so a library that called it late moves the call into `Opened`. No event loop on sockets has passed the suite yet, and the first one may amend the contract. It has been exercised by the in-memory event loop, by the wrapper over it, and by a loop that supplies only the core.

## 10. Known gaps

*Candidate event loops and what the mapping found.* For each candidate the mapping documents in `docs/event-loops/` (a TCP proxy's engine, uSockets, io_uring, libuv, libevent) give one row for every operation and event, arranged as the contract is, marked as checked against source at a named revision or as unverified, with the adapter work listed, and a section on what a loop with only the core costs. Where a substrate did not offer an operation directly (`reset` and `pause_reading` in uSockets, `shutdown_write` in libevent and io_uring) the strategies tried are in the document of that event loop under "Known gaps", and the result is adapter code.

What this does not establish: nothing was built or run, and several rows are unverified (they are listed at the top of each document). An event loop's adapter may find a row that cannot be met; it then records what it tried, and the contract is changed only if no other way works.

Three behaviours that every adapter has to supply, found by the reading and worth knowing before starting one:

- **Closing without losing accepted bytes.** `close(2)` on a socket with unread input resets the connection on Linux. Each mapping says how its event loop avoids it: finish sending, `shutdown(WR)`, discard input until the peer's end of stream or a limit, then close. The limit is the event loop's own and ends a peer that never reads.
- **`Writable` after the largest refused send fits.** a TCP proxy's engine may deliver it at a fixed low-water mark; the adapter has to remember the size that was refused.
- **Events never inside an operation.** uSockets calls its close callback before `us_socket_close` returns; libuv and libevent (with deferred callbacks) do not. An adapter over uSockets queues its events.

## 11. What the contract does not cover

(*What the contract covers*) These were found by looking at what client libraries need. Each is an addition above or beside the contract, not a change to it.

| Need | Who has it | Position |
|---|---|---|
| Host-name resolution | uSockets (blocking `getaddrinfo` inside connect), libuv (`uv_getaddrinfo`), libevent (`bufferevent_socket_connect_hostname`) | Not in the contract. An event loop never resolves; a host name given to `dial` fails with `ConnectFailed`, `BadAddress`. Needed before the first real client: a resolver library on the contract, or a wake from another thread so a resolver thread can post a result. |
| TLS | inside uSockets; separate in libuv | A wrapping event loop (*Event loops can be layered*; `tests/support/wrapper.goose` shows the layering). |
| Hosting existing C clients (libpq, hiredis, libcurl, c-ares) | They need "tell me when this descriptor is readable"; every readiness substrate offers it | Cannot be in the contract: an in-memory or completion-only event loop has no descriptors. A later optional capability. |
| Wake from another thread | `us_wakeup_loop`, `uv_async_send`, ring `MSG_RING`, a proxy's message pipes | A later optional capability. |
| Socket options | all | Event loop configuration. Event loops are advised to disable Nagle's algorithm, as proxies do. |
| Writing into received bytes in place (WebSocket unmasking) | uSockets, io_uring buffers | `Data` lends read-only bytes. Can be relaxed later. |

## 12. Open questions

- **Zero-copy sends and more than two parts.** A block form in which the event loop lends part of its send queue for the library to fill. Decide when a real event loop shows the cost of the copy; it is an addition.
- **Name resolution** (see section 11).
- **Descriptor readiness as an optional capability**, so existing C clients can be hosted on event loops that have descriptors.
- **A wake from another thread**, for a resolver thread for example. Outside the contract; decide with the first library that needs it.
- **A readiness adapter** so goose-http and goose-wing can provide the contract cheaply: decide when one of them adopts.
- **How a `Data` slice maps onto a coroutine resume value** once `coro fn` exists.
- **Can the uSockets example deliver received bytes without a copy?** The reading says not with upstream as it is (`docs/event-loops/usockets.md`, row `Data`): the receive buffer is one buffer for the loop and is reused at once. Open for a build that adds a synchronous call into Goose from the read callback.
- **Is any rule of the core still too heavy for a real loop?** The first real event loop answers it; until then none is weakened.
- **`draining` in the core.** It could be an inspection operation if the application, not the library, told libraries to wind down. Kept in the core because both examples need it and it costs a flag.

Answered: *how does each real event loop close without losing the reply?* Each mapping document has a section "Closing".
