# The goose-io contract

Version 0.1. The declarations are in [`goose_io.goose`](../goose_io.goose); this document is the meaning. The normative requirements, each with test scenarios, are in the OpenSpec capability `io-contract`. Requirement names from it are quoted in *italics* below so that every rule here can be traced to its tests.

## 1. Purpose and roles

Only one loop can own a thread. If every loop has its own way to dial, send and receive, every client library has to be written once per loop. This contract is the one way.

| Role | Does | Depends on |
|---|---|---|
| **Event loop** | Owns the thread and the sockets. Delivers events, performs operations. A real one is built on epoll, io_uring, libuv or uSockets; the in-memory one in this repository is built on nothing. | The contract, plus whatever it is built on. |
| **Library** | Handles events, calls operations. An HTTP server, a Postgres client. | The contract only. Never an event loop's own types. |
| **Application** | The program. Constructs an event loop, runs it, passes each event to its libraries. | The contract and one event loop. |

No role stores a callback, allocates from a heap, or calls through a function pointer (*Three roles: event loop, library, application*). The contract package is Goose source only and links nothing (*The contract package is pure Goose*). No file descriptor, socket address structure or poll mask crosses it (*The contract exposes no operating-system primitives*).

The contract is per loop. One loop runs on one thread. Every event is delivered on that thread and every operation is called on it: from a handler, or by the application before `serve`. Calling an operation from another thread is not supported, and the contract has no operation that crosses threads. A link or a listener is used only on the loop that created it. Starting several loops is the event loop's business.

**Who calls what.** A library calls the link operations only on its own links, the ones carrying its tag, and the listener operations only on its own listeners. `serve` and `stop` belong to the application. `tick_by` is shared by design (section 5). Nothing a library can call changes what another library sees.

## 2. A core and groups of extras

(*The contract is a core and groups of extras*, *The core is thirteen operations and five events*, *Each group is named and checked on its own*)

An event loop has to supply **the core**: 13 operations and 5 events, enough for a client or a server that answers requests. Everything else is in one of five **groups** that an event loop may supply or leave out. A library uses what it needs and says so in its header; built against a loop that lacks something it calls, it fails to compile, and the error names the operation.

| | Operations | Events |
|---|---|---|
| **Core** | `listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `set_user`, `now_ms`, `tick_by`, `serve`, `stop`, `draining` | `Opened`, `Data`, `Writable`, `Closed`, `Tick` |
| **Half-close** | `shutdown_write`, `set_keep_open_on_eof` | `PeerEof` |
| **Sizing** | `send_room`, `send2` | |
| **Abort** | `reset` | |
| **Inspection** | `peer_address`, `stop_listening`, `user` | |
| **Batching** | | `PassEnd` |

A rule that belongs to a group binds only an event loop that supplies the group, and no rule of the core depends on a group. A loop that supplies only the core conforms to the core, and a library that uses only the core runs on it unchanged.

`listener_port` and `pause_reading` are in the core although they look like extras: a suite that runs both ends of every link on one loop cannot otherwise reach a system-chosen port or make a peer that does not read.

**Checking at compile time.** The contract package has one check for the core, `require_core(io)`, and one for each group that has operations: `require_half_close`, `require_sizing`, `require_abort` and `require_inspection`. Each names every operation of its part once, with the contract's types, and never runs. An event loop's root program calls the check of the core and of each group it supplies, so that a missing or mistyped operation is an error at that one line. A library's test calls the checks for what the library's header says it needs. Batching has only an event and so no check; the conformance suite shows that a loop delivers `PassEnd` as it must.

**What an event loop that lacks a group does.** It never delivers that group's events: without half-close there is no `PeerEof`, since nothing could ask for it, and without batching no `PassEnd`. A library's handling of an event its loop never delivers is simply never run.

## 3. Types

All are fixed-size values.

| Type | Shape | Meaning |
|---|---|---|
| `Link` | `{ slot: u32, gen: u32 }` | A connection. The default value is invalid. `is_valid(link)`, `same(a, b)`. |
| `Listener` | `{ id: u32 }` | A listening endpoint. The default value means "none". `is_listener(l)`, `same(a, b)`. An id is never given to a second listener of the same loop. |
| `Address` | `{ text: u8[..56] }` | A numeric endpoint as text. Empty when unknown. `is_empty(a)`. |
| `SendStatus` | `Sent`, `Full`, `TooLarge`, `NotOpen`, `Closed` | Result of `send` and `send2`. |
| `CloseReason` | `PeerClosed`, `PeerReset`, `ConnectFailed { kind }`, `IdleTimeout`, `HalfCloseTimeout`, `Local`, `Shutdown`, `Error`, `LoopSpecific { code }` | Why a link ended. `is_portable(why)`, `is_connect_failed(why)`. |
| `ConnectFailure` | `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress`, `Other` | Why a dial did not open. See section 4. |
| `ListenError` | `{ kind: ListenErrorKind, code: i32 }` with kind `None`, `AddressInUse`, `BadAddress`, `Denied`, `NoResources`, `Other` | Result of `listen`. `failed(e)`. |
| `Event` | see sections 4 and 6 | What the application's handler receives. At most 32 bytes. |

**Addresses** are numeric text: `ip:port` for IPv4 and `[ip]:port` for IPv6, the same on every event loop, with IPv6 as hexadecimal groups. An event loop may accept more text than that (`inet_pton` takes `::ffff:192.0.2.1`), and a portable library passes only this form; the in-memory event loop treats an IPv4 tail as malformed. An event loop never resolves a host name, so there is no lookup to block the loop or to count against `connect_ms`; a host name given to `dial` fails with `ConnectFailed`. An IPv6 zone identifier (`%eth0`) is not part of an address and makes it malformed.

**Handles.** A link handle is valid from the `dial` or `Opened` that produced it until the handler of its `Closed` event returns; during that handler `user` and `peer_address` (where the loop supplies them) still work. After that it is stale and every operation on it does nothing. The generation is a guard against mistakes, not a licence to keep a handle: a slot's generation repeats after it has been used 2^32 times, so a library drops a handle when it sees its `Closed`. A listener handle is never reused at all (*Listener handles are never reused*); a loop that has issued every handle it can fails `listen` with `NoResources` and never starts again from an old one.

**Tags and user values.** A tag is 16 bits, chosen by the application, one per library; it is given to `dial` and `listen` and comes back in every event of the links they create. A user value is 32 bits, chosen by the library, set with `set_user`; it comes back in every later event of that link and is zero until set. A library uses the tag to recognise its events and the user value to find its own connection record without a lookup. The core has no operation that reads the value back (`user(link)` is inspection): a library keeps it in its own record.

## 4. The core

Every operation is a function whose first parameter is the event loop, called by method syntax: `io.send(link, bytes)`. Every operation except `serve` may be called from inside a handler and by the application before `serve`.

An operation on a link whose handle is invalid or stale (its `Closed` has been delivered, or the slot now belongs to another link) has no effect and touches no other link (*Links are generation-checked handles*). The last column says what it returns in that case.

### Operations

| Operation | Result | Effect | Stale or unknown handle |
|---|---|---|---|
| `listen(address, tag)` | `Listener, ListenError` | Starts accepting TCP connections. Each accepted connection produces `Opened` carrying `tag` and this listener. On failure the listener is "none", the error says why, and no events follow. (*Listening*) | n/a |
| `listener_port(listener)` | `u16` | The bound port, including one the system chose for port 0. | 0 |
| `dial(address, tag, connect_ms)` | `Link` | Starts an outbound connection and returns a valid link at once. Never blocks. `connect_ms` of 0 means the event loop's default. | n/a |
| `send(link, bytes)` | `SendStatus` | Takes every byte, or none. See below. | `Closed` |
| `max_send()` | `i64` | The largest single send this event loop can ever accept. At least 4096. One value for every link of the loop, and it does not change while the loop runs. | n/a |
| `pause_reading(link, paused)` | none | While paused, no `Data` is delivered and the event loop does not read, so the peer is held back. | no effect |
| `close(link)` | none | Sends what was accepted, then ends the connection cleanly. On a link that has not opened, cancels the dial. | no effect |
| `set_user(link, user)` | none | Sets the user value carried by every later event of the link. Works as soon as `dial` has returned. | no effect |
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
| `Opened` | link, tag, user, listener | The link is open. `listener` is "none" for a dialled link. |
| `Data` | link, tag, user, bytes | Bytes from the peer, in order. |
| `Writable` | link, tag, user | One or more sends were refused with `Full` and each of them would now fit. Once, however many were refused. |
| `Closed` | link, tag, user, why | The link is gone. |
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

**Ownership** (*Every link event names its owner*): every link event carries its tag and user value. A library treats a link event whose tag is not its own as not handled. `Tick` carries no tag and is offered to every library, and so is `PassEnd` where the loop supplies batching.

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
| `Closed` | The link is closing, closed or write-shut, or the handle is stale. | nothing |

They are decided in this order: `Closed`, `NotOpen`, then a send of zero bytes on an open link returns `Sent`, then `TooLarge`, then `Full`.

An event loop bounds what it holds unsent for each link, so a peer that never reads cannot make memory grow. A library that wants to know how much a send would take now asks the sizing group's `send_room`; with the core alone it sends, and on `Full` waits for `Writable`.

**`Writable`** (*Writable follows Full once*) works by episode, not by call:

1. The first `Full` on a link starts an episode. Further `Full` results during it add nothing.
2. The event loop delivers one `Writable` once each send refused during the episode would fit on its own, which is to say once the largest of them would. Not all of them together, and not the first free byte: a library that was refused 2000 bytes is not woken to find room for 100.
3. That ends the episode. The library retries; the send that was refused now returns `Sent`, unless the library itself has sent on the link in between. A `Full` after it starts a new episode with its own `Writable`.

A link that was never refused gets no `Writable`, and `TooLarge` never leads to one. The event carries no size.

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

**Why a dial failed** (*A failed dial says why*). `ConnectFailed` carries a kind. An event loop translates what its system reports into one of these and never passes an error number through. `Other` is always an honest answer when it cannot tell.

| Kind | Means | An event loop reports it when |
|---|---|---|
| `Refused` | Nothing accepts connections at the address. | the system reports a refused connection |
| `TimedOut` | No answer in time. | `connect_ms` elapsed, or the system gave up waiting |
| `Unreachable` | No route to the address, its network or its machine. | the system reports it |
| `Denied` | The system does not allow the connection. | the system reports it |
| `NoResources` | Out of links, descriptors, ports or memory. | the event loop has no link left, or the system reports exhaustion |
| `BadAddress` | The text is not a numeric address. | it is malformed, a host name, or has a zone identifier |
| `Other` | Anything else. | no kind above fits, or the event loop cannot tell |

`BadAddress`, `TimedOut` on `connect_ms`, and `NoResources` for the event loop's own links are always exact, because the event loop decides them itself. The kind is for reporting and for choosing how to retry: a library has a rule for the kinds it cares about and treats every other kind as it treats `Other`.

**Dialling** (*Dialling never blocks and always ends in one event*): `dial` returns a valid link immediately. The outcome is `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed or a host name, the connection is refused or unreachable, the event loop is out of resources, or the connect time passes. `send` before `Opened` returns `NotOpen`. `set_user` right after `dial` takes effect for every event of the link, including the `Closed` of a dial that failed at once. `dial` never returns an invalid link: an event loop that is out of link slots still returns a handle and reports the failure as that link's `Closed`, and it reads the user value when it delivers the event, not when `dial` was called.

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

(*The application runs and stops the loop*, *Draining is the same on every event loop*)

`serve` runs the loop on the calling thread. From the call to `stop(grace_ms)`:

1. Every listener stops at once, `draining()` is true, and `listen` fails.
2. Links keep working, and `dial` still works, so a library can finish work in hand. Events go on as before. A link dialled now ends with the same grace period; it does not extend it.
3. `serve` returns as soon as no link is left: none open, none dialling, none whose `Closed` is still to be delivered.
4. At the end of the grace period the event loop closes every link that is left with reason `Shutdown`, delivers those `Closed` events, and then `serve` returns. A grace period of 0 does this in the current pass.

Of several calls to `stop` the earliest end of grace stands. A loop whose `serve` has returned is finished and is not run again.

## 5. Time shared between libraries

`tick_by` is the one operation several libraries share: the event loop keeps the earliest request, and every library is offered every `Tick`, so a library that wants a later wake asks again on the `Tick` it gets.

## 6. The groups

Each group is a small set of operations and events with rules that bind only a loop that supplies it.

### Half-close

(*Peer end of stream and half-close*) Operations `set_keep_open_on_eof(link, keep)` and `shutdown_write(link)`, event `PeerEof`.

- By default, as in the core, the event loop sends what was accepted and closes the link with reason `PeerClosed` when the peer finishes.
- After `set_keep_open_on_eof(link, true)` (to be called before the peer's end of stream, usually while handling `Opened`) the event loop delivers `PeerEof` once, after all `Data`, and keeps the link open for sending. The library ends it with `shutdown_write` or `close`.
- `shutdown_write` ends this side's sending while still receiving: bytes already accepted are sent, the peer sees end of stream after them, `send` afterwards returns `Closed`, and `Data` and `PeerEof` still arrive. When both sides have finished, the link closes with reason `PeerClosed`.

| Operation | Result | Precondition | Stale handle |
|---|---|---|---|
| `set_keep_open_on_eof(link, keep)` | none | before the peer's end of stream | no effect |
| `shutdown_write(link)` | none | link is open | no effect |

A line server that answers what it has read after the peer finished sending needs this group.

### Sizing

(*Send backpressure is explicit and bounded*, *Two parts can be sent as one*) Operations `send_room(link)` and `send2(link, first, second)`.

- `send_room` is the number of bytes a send would accept now, never more than `max_send()`, and 0 before `Opened`, after `close`, `reset` or `shutdown_write`, and for a stale handle.
- `send2` is one `send` of the two ranges joined: a header and a body, or a frame prefix and a payload. Its size for `Full`, `TooLarge` and `send_room` is the sum of the two lengths, and it never takes one part without the other.

| Operation | Result | Stale handle |
|---|---|---|
| `send_room(link)` | `i64` | 0 |
| `send2(link, first, second)` | `SendStatus` | `Closed` |

Without sizing a library joins the two parts itself into a buffer of its own, and learns that a send did not fit from `Full`.

### Abort

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

(*A link reports its peer's address*, *Listening*) Operations `peer_address(link)`, `stop_listening(listener)` and `user(link)`.

- `peer_address` is the remote endpoint as numeric text in the form `dial` accepts, available from the link's `Opened` until its `Closed` has been delivered, and empty for a link that is not open. IPv6 is written in lower case with the longest run of two or more zero groups as `::`.
- `stop_listening` accepts no new connections on that listener. Links already accepted stay open, and the handle is never given to a later listener.
- `user` is the value last given to `set_user`, 0 for a stale handle.

| Operation | Result | Stale or unknown handle |
|---|---|---|
| `peer_address(link)` | `Address` | empty |
| `stop_listening(listener)` | none | no effect |
| `user(link)` | `u32` | 0 |

### Batching

(*End-of-pass notification*) Event `PassEnd`, no operation. It is the last event of every pass that delivered at least one link event; it lets a library batch: handle ten requests, then send ten replies at once. It is never delivered for a pass that delivered only a `Tick` or nothing. Calls made while handling it behave as anywhere else; the events they cause do not produce a second `PassEnd` for the same pass. It is the last event of its pass: no link event and no `Tick` of that pass comes after it, so what a library sends while handling it covers everything the pass did. It is always delivered by a loop that supplies the group: there is nothing to ask for and nothing to turn off, so one library cannot take it away from another. The application offers it to every library once; a library that does not batch ignores it.

## 7. Layering

(*Event loops can be layered*)

An event loop may wrap another: TLS, compression, a recorder. The wrapper presents this same contract upward, supplying the groups it passes through, and may delay `Opened` (a handshake), change the size of what is sent or received, and close a link with a loop-specific reason. Nothing in the contract lets a library tell a wrapped link from a plain one.

## 8. Scope

(*What the contract covers*)

The contract covers TCP byte streams over IPv4 and IPv6, ticks and deadlines, and running and stopping one loop, and nothing else. An event loop that implements exactly the core conforms to it; nothing in a group is required of an event loop that does not supply the group.

## 9. Versioning

(*The contract states its version*)

`goose_io::VERSION_MAJOR` and `goose_io::VERSION_MINOR`. While the major number is 0, a minor increase may change or remove behaviour. From major version 1, a minor increase only adds. An event loop states the contract version it conforms to, the core and the groups it supplies.

The version of this document is **0.1** (`VERSION_MAJOR` 0, `VERSION_MINOR` 1 in `goose_io.goose`), the first release. No event loop on sockets has passed the suite yet, and the first one may amend the contract. It has been exercised by the in-memory event loop, by the wrapper over it, and by a loop that supplies only the core.

## 10. Known gaps

*Candidate event loops and what the mapping found.* For each candidate the mapping documents in `docs/event-loops/` (tcprouter's engine, uSockets, io_uring, libuv, libevent) give one row for every operation and event, grouped as the contract is, marked as checked against source at a named revision or as unverified, with the adapter work listed, and a section on what a loop with only the core costs. Where a substrate did not offer an operation directly (`reset` and `pause_reading` in uSockets, `shutdown_write` in libevent and io_uring) the strategies tried are in the document of that event loop under "Known gaps", and the result is adapter code.

What this does not establish: nothing was built or run, and several rows are unverified (they are listed at the top of each document). An event loop's adapter may find a row that cannot be met; it then records what it tried, and the contract is changed only if no other way works.

Three behaviours that every adapter has to supply, found by the reading and worth knowing before starting one:

- **Closing without losing accepted bytes.** `close(2)` on a socket with unread input resets the connection on Linux. Each mapping says how its event loop avoids it: finish sending, `shutdown(WR)`, discard input until the peer's end of stream or a limit, then close. The limit is the event loop's own and ends a peer that never reads.
- **`Writable` after the largest refused send fits.** tcprouter delivers it at a fixed low-water mark; the adapter has to remember the size that was refused.
- **Events never inside an operation.** uSockets calls its close callback before `us_socket_close` returns; libuv and libevent (with deferred callbacks) do not. An adapter over uSockets queues its events.

## 11. What the contract does not cover

(*What the contract covers*) These were found by looking at what client libraries need. Each is an addition above or beside the contract, not a change to it.

| Need | Who has it | Position |
|---|---|---|
| Host-name resolution | uSockets (blocking `getaddrinfo` inside connect), libuv (`uv_getaddrinfo`), libevent (`bufferevent_socket_connect_hostname`) | Not in the contract. An event loop never resolves; a host name given to `dial` fails with `ConnectFailed`, `BadAddress`. Needed before the first real client: a resolver library on the contract, or a wake from another thread so a resolver thread can post a result. |
| TLS | inside uSockets; separate in libuv | A wrapping event loop (*Event loops can be layered*; `tests/support/wrapper.goose` shows the layering). |
| Hosting existing C clients (libpq, hiredis, libcurl, c-ares) | They need "tell me when this descriptor is readable"; every readiness substrate offers it | Cannot be in the contract: an in-memory or completion-only event loop has no descriptors. A later optional capability. |
| Wake from another thread | `us_wakeup_loop`, `uv_async_send`, ring `MSG_RING`, tcprouter's message pipes | A later optional capability. |
| Unix sockets | uSockets, libuv | An address form (`unix:/path`) can be added without changing any operation. |
| Socket options | all | Event loop configuration. Event loops are advised to disable Nagle's algorithm, as tcprouter does. |
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
