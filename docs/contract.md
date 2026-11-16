# The goose-io contract

Version 0.1. The declarations are in [`goose_io.goose`](../goose_io.goose); this document is the meaning. The normative requirements, each with test scenarios, are in the OpenSpec capability `io-contract`. Requirement names from it are quoted in *italics* below so that every rule here can be traced to its tests.

## 1. Purpose and roles

Only one loop can own a thread. If every loop has its own way to dial, send and receive, every client library has to be written once per loop. This contract is the one way.

| Role | Does | Depends on |
|---|---|---|
| **Provider** | Owns the loop. Delivers events, performs operations. | The contract, plus whatever it is built on. |
| **Library** | Handles events, calls operations. An HTTP server, a Postgres client. | The contract only. Never a provider's own types. |
| **Host** | The application. Constructs a provider, runs the loop, passes each event to its libraries. | The contract and one provider. |

No role stores a callback, allocates from a heap, or calls through a function pointer (*Three roles, one contract*). The contract package is Goose source only and links nothing (*The contract package is pure Goose*). No file descriptor, socket address structure or poll mask crosses it (*The contract exposes no operating-system primitives*).

The contract is per loop. One loop runs on one thread. Every event is delivered on that thread and every operation is called on it: from a handler, or by the host before `serve`. Calling an operation from another thread is not supported, and the base contract has no operation that crosses threads. A link or a listener is used only on the loop that created it. Starting several loops is the provider's business.

**Who calls what.** A library calls the link operations only on its own links, the ones carrying its tag, and the listener operations only on its own listeners. `serve` and `stop` belong to the host. `tick_by` is shared by design (section 7). Nothing a library can call changes what another library sees.

## 2. Types

All are fixed-size values.

| Type | Shape | Meaning |
|---|---|---|
| `Link` | `{ slot: u32, gen: u32 }` | A connection. The default value is invalid. `is_valid(link)`, `same(a, b)`. |
| `Listener` | `{ id: u32 }` | A listening endpoint. The default value means "none". `is_listener(l)`, `same(a, b)`. An id is never given to a second listener of the same loop. |
| `Address` | `{ text: u8[..56] }` | A numeric endpoint as text. Empty when unknown. `is_empty(a)`. |
| `SendStatus` | `Sent`, `Full`, `TooLarge`, `NotOpen`, `Closed` | Result of `send` and `send2`. |
| `CloseReason` | `PeerClosed`, `PeerReset`, `ConnectFailed { kind }`, `IdleTimeout`, `HalfCloseTimeout`, `Local`, `Shutdown`, `Error`, `Provider { code }` | Why a link ended. `is_portable(why)`, `is_connect_failed(why)`. |
| `ConnectFailure` | `Refused`, `TimedOut`, `Unreachable`, `Denied`, `NoResources`, `BadAddress`, `Other` | Why a dial did not open. See section 6. |
| `ListenError` | `{ kind: ListenErrorKind, code: i32 }` with kind `None`, `AddressInUse`, `BadAddress`, `Denied`, `NoResources`, `Other` | Result of `listen`. `failed(e)`. |
| `Event` | see section 4 | What the host's handler receives. At most 32 bytes. |

**Addresses** are numeric text: `ip:port` for IPv4 and `[ip]:port` for IPv6, the same on every provider, with IPv6 as hexadecimal groups. A provider may accept more text than that (`inet_pton` takes `::ffff:192.0.2.1`), and a portable library passes only this form; the in-memory provider treats an IPv4 tail as malformed. A provider never resolves a host name, so there is no lookup to block the loop or to count against `connect_ms`; a host name given to `dial` fails with `ConnectFailed`. An IPv6 zone identifier (`%eth0`) is not part of an address and makes it malformed. `peer_address` writes IPv6 in lower case with the longest run of two or more zero groups as `::`.

**Handles.** A link handle is valid from the `dial` or `Opened` that produced it until the handler of its `Closed` event returns; during that handler `user` and `peer_address` still work. After that it is stale and every operation on it does nothing. The generation is a guard against mistakes, not a licence to keep a handle: a slot's generation repeats after it has been used 2^32 times, so a library drops a handle when it sees its `Closed`. A listener handle is never reused at all (*Listener handles are never reused*); a loop that has issued every handle it can fails `listen` with `NoResources` and never starts again from an old one.

**Tags and user values.** A tag is 16 bits, chosen by the host, one per library; it is given to `dial` and `listen` and comes back in every event of the links they create. A user value is 32 bits, chosen by the library, set with `set_user`; it comes back in every later event of that link and is zero until set. A library uses the tag to recognise its events and the user value to find its own connection record without a lookup.

## 3. Operations

Every operation is a function whose first parameter is the provider, called by method syntax: `io.send(link, bytes)`. Every operation except `serve` may be called from inside a handler and by the host before `serve`.

An operation on a link whose handle is invalid or stale (its `Closed` has been delivered, or the slot now belongs to another link) has no effect and touches no other link (*Links are generation-checked handles*). The last column says what it returns in that case.

### Listening (*Listening*)

| Operation | Result | Effect | Stale or unknown handle |
|---|---|---|---|
| `listen(address, tag)` | `Listener, ListenError` | Starts accepting TCP connections. Each accepted connection produces `Opened` carrying `tag` and this listener. On failure the listener is "none", the error says why, and no events follow. | n/a |
| `listener_port(listener)` | `u16` | The bound port, including one the system chose for port 0. | 0 |
| `stop_listening(listener)` | none | No new connections. Links already accepted stay open. | no effect |

Whether two listeners on overlapping addresses (the wildcard and a specific address, or one address on both) may coexist on one loop is up to the provider: a library does not depend on it, and does not listen twice on one port. The in-memory provider refuses the second with `AddressInUse`.

### Links

`peer_address` is covered by *A link reports its peer's address*: the value is available from the link's `Opened` event until its `Closed` event has been delivered.

| Operation | Result | Precondition | Effect | Stale handle |
|---|---|---|---|---|
| `dial(address, tag, connect_ms)` | `Link` | none | Starts an outbound connection and returns a valid link at once. Never blocks. `connect_ms` of 0 means the provider's default. | n/a |
| `peer_address(link)` | `Address` | link is open | The remote endpoint as numeric text. | empty |
| `send(link, bytes)` | `SendStatus` | none | Takes every byte, or none. See section 5. | `Closed` |
| `send2(link, first, second)` | `SendStatus` | none | As one `send` of the two ranges joined. | `Closed` |
| `send_room(link)` | `i64` | none | Bytes a send would accept now. Never more than `max_send()`. 0 before `Opened`, after `close`, `reset` or `shutdown_write`. | 0 |
| `max_send()` | `i64` | none | The largest single send this provider can ever accept. At least 4096. One value for every link of the loop, and it does not change while the loop runs. | n/a |
| `pause_reading(link, paused)` | none | none | While paused, no `Data` is delivered and the provider does not read, so the peer is held back. | no effect |
| `set_keep_open_on_eof(link, keep)` | none | before the peer's end of stream | Chooses what the peer's end of stream does. See section 6. | no effect |
| `shutdown_write(link)` | none | link is open | Ends this side's sending once accepted bytes are out. Later sends return `Closed`. | no effect |
| `close(link)` | none | none | Sends what was accepted, then ends the connection cleanly. On a link that has not opened, cancels the dial. See section 6. | no effect |
| `reset(link)` | none | none | Closes at once and discards unsent bytes. The peer sees an abort. | no effect |
| `set_user(link, user)` | none | none | Sets the user value carried by every later event of the link. Works as soon as `dial` has returned. | no effect |
| `user(link)` | `u32` | none | The user value. | 0 |

### Time

| Operation | Result | Effect |
|---|---|---|
| `now_ms()` | `i64` | The loop's clock in milliseconds. Monotonic; never goes backwards. Not wall-clock time. |
| `tick_by(at_ms)` | none | Asks for a `Tick` at or after `at_ms`. A provider keeps only the earliest outstanding request, and the first such `Tick` satisfies it, so a library asks again while handling a `Tick` if it still has a deadline. |

### Host (*The host runs and stops the loop*)

| Operation | Result | Effect |
|---|---|---|
| `serve() { io, ev => ... }` | returns when stopped | Runs the loop on the calling thread and calls the block once per event. |
| `stop(grace_ms)` | none | Starts draining. See below. |
| `draining()` | `bool` | True once `stop` has been called. A library that sees it should finish and close its links. |

**Stopping** (*The host runs and stops the loop*, *Draining is the same on every provider*). From the call to `stop(grace_ms)`:

1. Every listener stops at once, `draining()` is true, and `listen` fails.
2. Links keep working, and `dial` still works, so a library can finish work in hand. Events go on as before. A link dialled now ends with the same grace period; it does not extend it.
3. `serve` returns as soon as no link is left: none open, none dialling, none whose `Closed` is still to be delivered.
4. At the end of the grace period the provider closes every link that is left with reason `Shutdown`, delivers those `Closed` events, and then `serve` returns. A grace period of 0 does this in the current pass.

Of several calls to `stop` the earliest end of grace stands. A loop whose `serve` has returned is finished and is not run again.

`require_provider(io)` in the contract package names every operation above once with these types and never runs; a provider's root program calls it so that a missing operation is a compile error in one place.

## 4. Events

The host supplies one handler. A provider delivers every event of the loop to it, on the loop's thread, one at a time, and never from inside an operation: an event caused by a call made in a handler arrives after that handler returns (*Events are delivered to one handler, one at a time*).

| Event | Carries | When |
|---|---|---|
| `Opened` | link, tag, user, listener | The link is open. `listener` is "none" for a dialled link. |
| `Data` | link, tag, user, bytes | Bytes from the peer, in order. |
| `Writable` | link, tag, user | One or more sends were refused with `Full` and each of them would now fit. Once, however many were refused. |
| `PeerEof` | link, tag, user | The peer finished sending. Only on a link that opted in. |
| `Closed` | link, tag, user, why | The link is gone. |
| `Tick` | now_ms | At least every 100 ms of the loop's clock, and at or after a time asked for with `tick_by`. |
| `PassEnd` | nothing | The last event of every pass that delivered at least one link event. |

**Order for one link** (*Link events follow a fixed order*):

| Situation | What the handler sees |
|---|---|
| A dial that succeeds, or an accepted connection | `Opened` first, before any other event of the link |
| A dial that fails, or that the library closes before it opens | one `Closed`, and no `Opened` |
| Bytes from the peer | `Data`, in the order the bytes arrived |
| The peer finishes sending, on a link that opted in | one `PeerEof`, after every `Data` |
| The link ends, for any reason | exactly one `Closed`, last |
| After `Closed` | nothing for that link, ever |
| After the library calls `close` or `reset` | nothing but that one `Closed` |

**Ownership** (*Every link event names its owner*): every link event carries its tag and user value. A library treats a link event whose tag is not its own as not handled. `Tick` and `PassEnd` carry no tag and are offered to every library.

**`Data` bytes are lent** (*Received bytes are lent for the duration of the event*): the slice belongs to the provider and is valid only until the handler returns. A library copies what it must keep, for example the unfinished tail of a message. A provider has at most one undelivered `Data` per link and reads no more from that link until the handler has returned.

**`PassEnd`** (*End-of-pass notification*) lets a library batch: handle ten requests, then send ten replies at once. It is never delivered for a pass that delivered only a `Tick` or nothing. Calls made while handling it behave as anywhere else; the events they cause do not produce a second `PassEnd` for the same pass. It is the last event of its pass: no link event and no `Tick` of that pass comes after it, so what a library sends while handling it covers everything the pass did. It is always delivered: there is nothing to ask for and nothing to turn off, so one library cannot take it away from another. The host offers it to every library once; a library that does not batch ignores it.

## 5. Sending and backpressure

(*Sending is all or nothing*, *Two parts can be sent as one*, *Send backpressure is explicit and bounded*)

`send` and `send2` take every byte or none.

| Result | Meaning | What follows |
|---|---|---|
| `Sent` | Every byte was taken: the provider is now responsible for them and the caller may reuse its memory at once. It does not mean the peer has received them. Bytes go out in the order sends were accepted, with no further call needed. | nothing |
| `Full` | Does not fit now. Nothing was taken. | One `Writable` once it would fit. |
| `TooLarge` | Larger than `max_send()`. Will never fit in one call. | Nothing. Send it in pieces. |
| `NotOpen` | The link has not opened yet. Nothing was queued. | Wait for `Opened`. |
| `Closed` | The link is closing, closed or write-shut, or the handle is stale. | nothing |

They are decided in this order: `Closed`, `NotOpen`, then a send of zero bytes on an open link returns `Sent`, then `TooLarge`, then `Full`.

A provider bounds what it holds unsent for each link, so a peer that never reads cannot make memory grow. `send_room(link)` is how much a send would accept now.

**`Writable`** (*Writable follows Full once*) works by episode, not by call:

1. The first `Full` on a link starts an episode. Further `Full` results during it add nothing.
2. The provider delivers one `Writable` once each send refused during the episode would fit on its own, which is to say once the largest of them would. Not all of them together, and not the first free byte: a library that was refused 2000 bytes is not woken to find room for 100.
3. That ends the episode. The library retries; the send that was refused now returns `Sent`, unless the library itself has sent on the link in between. A `Full` after it starts a new episode with its own `Writable`.

A link that was never refused gets no `Writable`, and `TooLarge` never leads to one. The event carries no size; `send_room` gives it.

**A refused send is always resolved** (*A refused send is always resolved*). After `Full` the link gets one `Writable` or its `Closed`; it never stays open and silent. It gets no `Writable` once its sending has ended by `shutdown_write`, `close` or `reset`, including one the provider had already queued: nothing can fit again, so the event would be untrue. When the peer goes away while a send is refused, a provider chooses between the two. A provider on sockets will usually see the reset and close the link. The in-memory provider delivers `Writable` after the link's `PeerEof` (when the library asked to keep the link open), and the retry is accepted and lost and resets the link.

`send2(link, first, second)` is one `send` of the two ranges joined: a header and a body, or a frame prefix and a payload. Its size for `Full`, `TooLarge` and `send_room` is the sum of the two lengths, and it never takes one part without the other.

To hold a peer back in the other direction, a library calls `pause_reading(link, true)` (*Reading can be paused*). A proxy that gets `Full` from one link pauses reading on the other and resumes on `Writable`.

## 6. The life of a link

```
 dial() ──► Dialling ──connect ok──► Open ──────────────────► Closed
                │                     │  ▲                      ▲
                │                     │  └ half-closed (either  │
                │                     │    side, see below)     │
                └── fails, times out, │                         │
                    or close() ───────┴── close, reset, peer, ──┘
 accepted by a listener ───────────► Open     provider, or stop
```

**Why a dial failed** (*A failed dial says why*). `ConnectFailed` carries a kind. A provider translates what its system reports into one of these and never passes an error number through. `Other` is always an honest answer when it cannot tell.

| Kind | Means | A provider reports it when |
|---|---|---|
| `Refused` | Nothing accepts connections at the address. | the system reports a refused connection |
| `TimedOut` | No answer in time. | `connect_ms` elapsed, or the system gave up waiting |
| `Unreachable` | No route to the network or host. | the system reports it |
| `Denied` | The system does not allow the connection. | the system reports it |
| `NoResources` | Out of links, descriptors, ports or memory. | the provider has no link left, or the system reports exhaustion |
| `BadAddress` | The text is not a numeric address. | it is malformed, a host name, or has a zone identifier |
| `Other` | Anything else. | no kind above fits, or the provider cannot tell |

`BadAddress`, `TimedOut` on `connect_ms`, and `NoResources` for the provider's own links are always exact, because the provider decides them itself. The kind is for reporting and for choosing how to retry: a library has a rule for the kinds it cares about and treats every other kind as it treats `Other`.

**Dialling** (*Dialling never blocks and always ends in one event*): `dial` returns a valid link immediately. The outcome is `Opened`, or exactly one `Closed` with reason `ConnectFailed` when the address is malformed or a host name, the connection is refused or unreachable, the provider is out of resources, or the connect time passes. `send` before `Opened` returns `NotOpen`. `set_user` right after `dial` takes effect for every event of the link, including the `Closed` of a dial that failed at once. `dial` never returns an invalid link: a provider that is out of link slots still returns a handle and reports the failure as that link's `Closed`, and it reads the user value when it delivers the event, not when `dial` was called.

**Closing** (*Closing*). Three operations end a link's sending, and they differ:

| | `shutdown_write` | `close` | `reset` |
|---|---|---|---|
| Bytes already accepted | sent | sent | discarded |
| What the peer sees | end of stream after those bytes | end of stream after those bytes | an abort (`PeerReset`) |
| Receiving afterwards | goes on: `Data` and `PeerEof` still arrive | stops: nothing more is delivered | stops |
| Waits for the peer | yes: the link closes when the peer has finished too | no | no |
| `send` afterwards | `Closed` | `Closed` | `Closed` |
| The link's last event | `Closed` with `PeerClosed`, when both sides are done | `Closed` with `Local` | `Closed` with `Local` |

After `close` or `reset` the only event the link still gets is its one `Closed`: no `Data` for bytes that had arrived, no `Writable` that was owed, no `PeerEof`. It is delivered after the handler that made the call has returned, when the provider has finished with the connection, which may be later than the same pass if accepted bytes are still going out. `stop` counts such a link as still present, so `serve` does not return while a reply is on its way.

**What `close` promises about bytes already accepted** (*Close does not lose accepted bytes*). There are three moments, and the contract covers the first two:

1. `send` returned `Sent`: the provider is responsible for the bytes.
2. The provider has handed them to the transport. After `close` a provider does this before it ends the connection, and input it has received but not delivered must not make it discard them. On some systems closing a socket that still has unread input aborts the connection and the peer loses bytes already sent to it; a provider has to avoid that, for example by finishing its sending first and discarding the input afterwards.
3. The peer's application has received and processed them. Nothing here promises that. A protocol that needs to know has the peer say so.

A provider may abandon accepted bytes after a limit of its own when the peer does not take them, so that a peer that never reads cannot hold a closed link for ever. The link's event is still its one `Closed` with reason `Local`.

**The peer's end of stream** (*Peer end of stream and half-close*):

- By default the provider sends what was accepted and closes the link with reason `PeerClosed`. This suits request/reply protocols where the peer closing means it is done.
- After `set_keep_open_on_eof(link, true)` the provider delivers `PeerEof` once, after all `Data`, and keeps the link open for sending. The library ends it with `shutdown_write` or `close`.
- `shutdown_write` ends this side's sending while still receiving. When both sides have finished, the link closes with reason `PeerClosed`.

**Close reasons** (*Close reasons are portable*):

| Reason | Meaning |
|---|---|
| `PeerClosed` | The peer finished cleanly, or both sides did. |
| `PeerReset` | The peer aborted. |
| `ConnectFailed { kind }` | A dial did not open. The kind says why. |
| `IdleTimeout`, `HalfCloseTimeout` | The provider's own limits, if it has them. |
| `Local` | This side called `close` or `reset`. |
| `Shutdown` | The loop stopped while the link was open. |
| `Error` | Any other failure. |
| `Provider { code }` | A reason only this provider has. The code is for logs. |

A provider may close a link on its own policy at any time. A portable library handles every reason and treats `Provider` as `Error`; it never branches on the code.

## 7. Time

(*Time and ticks*)

`now_ms()` is the loop's clock. It is read once per pass, so it does not move during a handler.

A library keeps its own deadlines. It asks for a wake with `tick_by(at_ms)` and checks its deadlines on every `Tick`. The provider keeps no timer table and there is nothing to cancel. `Deadlines` in `deadlines.goose` is a small bounded heap of `(at_ms, id)` for libraries that have many.

## 8. Layering

(*Providers can be layered*)

A provider may wrap another: TLS, compression, a recorder. The wrapper presents this same contract upward and may delay `Opened` (a handshake), change the size of what is sent or received, and close a link with a provider-specific reason. Nothing in the contract lets a library tell a wrapped link from a plain one.

## 9. Scope

(*Scope of the base contract*)

The base contract covers TCP byte streams over IPv4 and IPv6, ticks and deadlines, and running and stopping one loop. A provider that implements exactly this conforms.

## 10. Versioning

(*The contract states its version*)

`goose_io::VERSION_MAJOR` and `goose_io::VERSION_MINOR`. While the major number is 0, a minor increase may change or remove behaviour. From major version 1, a minor increase only adds. A provider states the contract version it conforms to.

The version of this document is **0.1** (`VERSION_MAJOR` 0, `VERSION_MINOR` 1 in `goose_io.goose`). Version 0.1 has been
exercised by one provider, the in-memory provider, and by the wrapper over it; no provider on sockets has passed the
suite yet, and the first one may amend the contract (design D13 of the change that introduced it).

## 11. Known gaps

*Candidate providers and what the mapping found.* For each candidate provider the mapping documents in
`docs/providers/` (tcprouter's engine, uSockets, io_uring, libuv, libevent) give one row for every operation and
event, marked as checked against source at a named revision or as unverified, with the adapter work listed. Read at
those revisions, every row has a workable mapping: no requirement of this contract had to be changed, and no
operation is recorded here as one a provider cannot supply. Where a substrate did not offer an operation directly
(`reset` and `pause_reading` in uSockets, `shutdown_write` in libevent and io_uring) the strategies tried are in the
document of that provider under "Known gaps", and the result is adapter code.

What this does not establish: nothing was built or run, and several rows are unverified (they are listed at the top
of each document). A provider's adapter may find a row that cannot be met; it then records what it tried and the
contract is changed only if no other way works.

Three behaviours that every adapter has to supply, found by the reading and worth knowing before starting one:

- **Closing without losing accepted bytes.** `close(2)` on a socket with unread input resets the connection on
  Linux. Each mapping says how its provider avoids it: finish sending, `shutdown(WR)`, discard input until the
  peer's end of stream or a limit, then close. The limit is the provider's own and ends a peer that never reads.
- **`Writable` after the largest refused send fits.** tcprouter delivers it at a fixed low-water mark; the adapter
  has to remember the size that was refused.
- **Events never inside an operation.** uSockets calls its close callback before `us_socket_close` returns; libuv
  and libevent (with deferred callbacks) do not. An adapter over uSockets queues its events.

## 12. What the base contract does not cover

(*Scope of the base contract*) These were found by looking at what client libraries need. Each is an addition above
or beside the base contract, not a change to it.

| Need | Who has it | Position |
|---|---|---|
| Host-name resolution | uSockets (blocking `getaddrinfo` inside connect), libuv (`uv_getaddrinfo`), libevent (`bufferevent_socket_connect_hostname`) | Not in the base contract. A provider never resolves; a host name given to `dial` fails with `ConnectFailed`, `BadAddress`. Needed before the first real client: a resolver library on the contract, or a wake from another thread so a resolver thread can post a result. |
| TLS | inside uSockets; separate in libuv | A wrapping provider (*Providers can be layered*; `tests/support/wrapper.goose` shows the layering). |
| Hosting existing C clients (libpq, hiredis, libcurl, c-ares) | They need "tell me when this descriptor is readable"; every readiness substrate offers it | Cannot be in the base contract: an in-memory or completion-only provider has no descriptors. A later optional capability. |
| Wake from another thread | `us_wakeup_loop`, `uv_async_send`, ring `MSG_RING`, tcprouter's message pipes | A later optional capability. |
| Unix sockets | uSockets, libuv | An address form (`unix:/path`) can be added without changing any operation. |
| Socket options | all | Provider configuration. Providers are advised to disable Nagle's algorithm, as tcprouter does. |
| Writing into received bytes in place (WebSocket unmasking) | uSockets, io_uring buffers | `Data` lends read-only bytes. Can be relaxed later. |

## 13. Open questions

Carried forward from the change that introduced the contract (design, "Open Questions"):

- **Zero-copy sends and more than two parts.** A block form in which the provider lends part of its send queue for the
  library to fill. Decide when a real provider shows the cost of the copy; it is an addition.
- **Name resolution** (see section 12).
- **Descriptor readiness as an optional capability**, so existing C clients can be hosted on providers that have descriptors.
- **A wake from another thread**, for a resolver thread for example. Outside the base contract; decide with the first
  library that needs it.
- **A readiness adapter** so goose-http and goose-wing can provide the contract cheaply: decide when one of them adopts.
- **How a `Data` slice maps onto a coroutine resume value** once `coro fn` exists.
- **Can the uSockets example deliver received bytes without a copy?** The reading says not with upstream as it is
  (`docs/providers/usockets.md`, row `Data`): the receive buffer is one buffer for the loop and is reused at once.
  Open for a build that adds a synchronous call into Goose from the read callback.

Answered by this change: *how does each real provider close without losing the reply?* Each mapping document has a
section "Closing".
