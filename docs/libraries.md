# Writing a library

A library is Goose code that speaks a protocol over links: an HTTP server, a database client, a
proxy. It is generic over the event loop, so the same source runs on any event loop that meets the
contract in [contract.md](contract.md).

**New here?** Read [`examples/echo/echo.goose`](../examples/echo/echo.goose) first: about 130 lines, the whole of a
server that answers every byte with the same byte, including what to do when the peer is too slow to read the answer.
Its test, [`tests/examples/echo_test.goose`](../tests/examples/echo_test.goose), shows how to run a library with no
network. Then come back here for the shape of a library and the rules it follows.

This document covers the shape of a library, what the contract gives it to work with, and how to test it with
no network. Every excerpt of code in it is copied from a file that the tests build and run, and
`tests/checks/docs.sh` fails if one drifts: `examples/lineserver/server.goose`, `examples/lineclient/client.goose`
and `examples/gateway.goose` are the libraries, and `tests/examples/` runs them on scripted peers.

## What a library needs

A library uses the **core** of the contract and, if it must, some of the **groups** (`contract.md`, section 2).
It says which in its header, in one line that `tests/examples/needs_check.sh` reads:

```text
// Needs: core only.                                   examples/lineclient/client.goose
// Needs: core and half-close (...).                   examples/lineserver/server.goose
```

and its test calls the matching checks, so that an event loop that lacks one fails with the name of the operation
and not somewhere inside the library:

```goose
goose_io::require_core(io);
goose_io::require_half_close(io);       // the line server keeps its link open after the peer finishes sending
```

The fewer groups a library needs, the more event loops it runs on, so ask first whether the core is enough. It
usually is: `send` and `Full` do what `send_room` and `send2` do (join the two parts into a buffer of your own, and
wait for `Writable` on `Full`), `close` ends a link as `shutdown_write` does for a protocol where the peer's end of
stream means it is done, `Tick` and `tick_by` replace `PassEnd` for a library that does not batch, and the user
value is yours to keep (`set_user` sets it; you do not need `user` to read it back). A library that needs a group
fails to build on an event loop without it, naming the operation. `examples/lineclient/` needs only the core and its
tests run on `tests/support/core_only.goose`; `examples/lineserver/` answers after the peer has finished sending, so it needs half-close.

An event the loop never delivers is simply never handled: the `PeerEof` and `PassEnd` arms of the example libraries
are never run on a loop without those groups.

## The shape of a library

A library is a **state struct** and **functions generic over the event loop**, with one **event entry point** that
says whether the event was its own. It imports the contract and nothing that names an event loop (the check is
`tests/examples/imports_test.sh`), so one source runs on every event loop that passes the conformance suite.

The state is one struct that the application owns: a local or a global variable, passed by reference. It holds the
library's tag, its listener or its pool of links, and its buffers. Buffers have fixed sizes in these examples, so
a peer that is too fast, too slow or silent cannot make the library grow; a library that needs more may use
growable arrays, with the one rule of Goose that an array element cannot itself be resizable.

<!-- excerpt: examples/lineserver/server.goose#state -->
```goose
root struct LineServer {
    tag:      u16                = 0,
    listener: goose_io::Listener = goose_io::Listener { .. },
    open:     i64                = 0,
    fulls:    i64                = 0,       // how many sends were refused with Full
    conns:    Conn[>..]          = [],
    free:     i64[>..<]          = [],
}
```

The entry point takes the library, the event loop and the event. It returns true when the event was for the
library and false when it is not: another library's, or a `Tick` or `PassEnd`, which every library is offered and
none owns.

<!-- excerpt: examples/lineserver/server.goose#entry -->
```goose
// The library's one entry point: true if the event was for this server, false if it is another library's (or
// a Tick or PassEnd, which every library is offered).
fn server_event<Io>(s: LineServer&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => {
            if io.draining() { s._close_idle(io); }
            return false;
        },
        PassEnd => { return false; },
        Opened e => {
            if e.tag != s.tag { return false; }
            s._on_opened(io, e.link);
            return true;
        },
        Data e => {
            if e.tag != s.tag { return false; }
            let i = s._conn_of(e.user, e.link);
            if i >= 0 { s._on_data(io, i, e.bytes); }
            return true;
        },
        Writable e => {
            if e.tag != s.tag { return false; }
            let i = s._conn_of(e.user, e.link);
            if i >= 0 {
                s._flush(io, i);
                s._finish_if_done(io, i);
            }
            return true;
        },
        PeerEof e => {
            if e.tag != s.tag { return false; }
            let i = s._conn_of(e.user, e.link);
            if i >= 0 {
                s.conns[i].eof = true;
                s._finish_if_done(io, i);
            }
            return true;
        },
        Closed e => {
            if e.tag != s.tag { return false; }
            let i = s._conn_of(e.user, e.link);
            if i >= 0 {
                s.conns[i].in_use = false;
                s.open--;
                s.free.push(i);
            }
            return true;
        },
    }
}
```

### Tags and the user value

Every link event names its owner. The **tag** is given to `listen` or `dial` and comes back on every event of the
link: it is how a library tells its links from another library's, and the application gives each library its own. The
**user value** is the library's own number for one link, set with `set_user` and carried by every later event of
that link. Both examples use it as an index into their table of connections, so an event leads straight to its
state, and check that the link in the table is the link in the event (`same`) before trusting the index. A link
that failed at once still carries the user value set after `dial` returned, so a library can set it right away.

### `Full` and `Writable`

`send` takes every byte or none. When it answers `Full` the library keeps what it could not send and waits: the
event loop delivers one `Writable` when each refused send would now fit, and the library tries again. Meanwhile it
must not take on more work for that link; both examples stop handing out requests for a link until its output is
empty, and a link that falls behind is held back with `pause_reading` until it has caught up. `max_send` says the largest send the loop will ever take, and with the sizing group `send_room` says how much a send would take now.

<!-- excerpt: examples/lineserver/server.goose#flush -->
```goose
// Sends what the event loop will take of the connection's output. A refusal waits for Writable.
fn _flush<Io>(s: LineServer&, io: Io&, i: i64) {
    let c .= s.conns[i];
    while c.in_use && c.out.len > c.sent {
        let left = c.out.len - c.sent;
        let n = if left < io.max_send() { left } else { io.max_send() };
        let status = io.send(c.link, c.out[c.sent..c.sent + n]);
        if status == goose_io::SendStatus.Sent {
            c.sent += n;
        } else if status == goose_io::SendStatus.Full {
            s.fulls++;
            return;
        } else {
            // Closed or anything else: the link is going, and so is what was waiting for it
            c.sent = c.out.len;
            return;
        }
    }
    if c.out.len == c.sent { c.out.clear(); c.sent = 0; }
}
```

Every `Full` is answered by one `Writable` or by the link's `Closed`; a library never waits for ever on a link
that has gone (*A refused send is always resolved*).

### Deadlines

The event loop keeps no timers. A library keeps its own deadlines in a `goose_io::Deadlines` (`deadlines.goose`, a
bounded heap of time and id) and asks for a wake with `tick_by(next_at)`. On every `Tick` it takes what is due,
and asks again for the next. The line client does this for each request's deadline and for the time to redial a
lost link.

<!-- excerpt: examples/lineclient/client.goose#expire -->
```goose
// Requests whose deadline has come: reported once; a request already sent keeps its place in the link's queue
// so that its reply, when it comes, is read and discarded.
fn _expire<Io>(c: LineClient&, io: Io&) {
    loop {
        let d = c.deadlines.pop_due(io.now_ms());
        if !d.found { break; }
        let k = c._find(d.id);
        if k >= 0 {
            let was = c.reqs[k].state;
            c._complete(d.id, Outcome.TimedOut, "");
            c.reqs[k].state = if was == R_SENT { R_ABANDONED } else { R_FREE };
        }
    }
}
```

A request that timed out stays in its link's queue marked abandoned, so that when its reply comes it is read and
thrown away: a late reply can never be taken for the reply of a later request.

<!-- excerpt: examples/lineclient/client.goose#rearm -->
```goose
// Asks the event loop to wake the client for its next deadline or redial, whichever is first.
fn _rearm<Io>(c: LineClient&, io: Io&) {
    if !c.deadlines.is_empty() { io.tick_by(c.deadlines.next_at()); }
    for i in c.size { if c.slots[i].state == BACKOFF { io.tick_by(c.slots[i].retry_at); } }
}
```

### While the loop is stopping

`stop(grace_ms)` makes `draining()` true. A library that sees it finishes what it has in hand and closes the
links it has no work on; when no link is left, `serve` returns, and what remains at the end of the grace period is
closed by the event loop with `Shutdown`. The line server closes the connections with nothing in progress on the
next `Tick`:

<!-- excerpt: examples/lineserver/server.goose#draining -->
```goose
// Closes every connection that has nothing in progress: what a library does when the loop is stopping.
fn _close_idle<Io>(s: LineServer&, io: Io&) {
    for i in s.conns.len {
        let c .= s.conns[i];
        if c.in_use && !c.closing && !c.busy && !_out_pending(c) && !_has_line(c) {
            c.closing = true;
            io.close(c.link);
        }
    }
}
```

A library may still `dial` while draining to finish work in hand; it may not `listen`.

### The application

The application is the only code that names an event loop, and it assigns the tags. It runs the loop and hands each event to
its libraries. `examples/gateway.goose` runs the line server twice (a front and a backend) and the line client on
one loop, and connects them without either library naming the other: the front's requests become the client's
requests to the backend, and the client's results become the front's replies.

<!-- excerpt: examples/gateway.goose#step -->
```goose
// One event for every library, then what the application does with what they have: the backend answers, the
// front's requests go to the client, and the client's results go back to the front's connections.
fn step<Io>(front: lineserver::LineServer&, back: lineserver::LineServer&, client: lineclient::LineClient&, table: Table&, io: Io&, ev: goose_io::Event) {
    if !front.server_event(io, ev) { if !back.server_event(io, ev) { client.client_event(io, ev); } }
    // a Tick or PassEnd is every library's: give the others theirs
    if !goose_io::is_link_event(ev) { back.server_event(io, ev); client.client_event(io, ev); }
    _backend(back, io);
    loop {
        var line: u8[>..] = [];
        let r = front.take_request(io, line);
        if !r.found { break; }
        let id = client.request(io, line[..], 2000);
        if id == 0 || !_remember(table, id, r) { front.reply(io, r, "error: busy"); }
    }
    // the backend may have been answered by the work above: give the client what has arrived
    loop {
        var text: u8[>..] = [];
        let res = client.take_result(text);
        if !res.found { break; }
        let r = _forget(table, res.id);
        match res.outcome {
            Ok => { front.reply(io, r, text[..]); },
            TimedOut => { front.reply(io, r, "error: timed out"); },
            LinkLost => { front.reply(io, r, "error: backend lost"); },
            Failed => { front.reply(io, r, "error: backend unavailable"); },
        }
    }
}
```

`tests/examples/gateway_test.goose` runs it, and checks that on `stop` every library closes its links so that
`serve` returns before the grace period ends.

## Testing a library

The package includes an event loop that needs no network and no real clock: `goose_io_memory::Loop`
in `memory.goose`. A test runs the library on it, plays the other end of each link with a
scripted peer, and reads back what the library sent. Time is a number that the loop moves
forward itself, so a test that covers ten seconds of timeouts finishes at once, and the same test
gives the same events at the same times on every run.

```goose
import goose_io from "../..";      // the package root, from where the test file is
import goose_io.memory;

var io = goose_io_memory::Loop { .. };
```

### An example

This is `tests/unit/library_example_test.goose`, whole. It holds a small library and its test.

<!-- source: tests/unit/library_example_test.goose -->
```goose
// A library tested with no network. This file is the example in docs/libraries.md,
// "Testing a library", and runs as a test.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

// --- the library ---------------------------------------------------------------------------------
// Sends back what it receives in upper case, and closes the link at the first '.'.

let SHOUT_TAG = 7;

struct Shout { links: i64 = 0, bytes: i64 = 0 }

// Returns false for an event that belongs to another library.
fn shout_event<Io>(lib: Shout&, io: Io&, ev: goose_io::Event) -> bool {
    guard goose_io::is_link_event(ev) && goose_io::tag_of(ev) == SHOUT_TAG else { return false; }
    match ev {
        Opened e => { lib.links++; },
        Data d => {
            var out: u8[>..] = [];
            var done = false;
            for c in d.bytes {
                if c == '.' { done = true; break; }
                out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c });
            }
            lib.bytes += out.len;
            io.send(d.link, out);
            if done { io.close(d.link); }
        },
        Closed e => { lib.links--; },
        _ => {},
    }
    return true;
}

// --- the test ------------------------------------------------------------------------------------

fn main() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.read_chunk = 4;                      // deliver in small pieces: the library must not care
    var lib = Shout { .. };
    let listener, err = io.listen("127.0.0.1:7000", SHOUT_TAG);
    kit::check(!goose_io::failed(err), "listen");

    // The client is a scripted peer: connect at once, send 10 ms later, send again 40 ms after that.
    let peer = io.add_peer();
    io.peer_connect(peer, "127.0.0.1:7000", 0);
    io.peer_send(peer, 10, "hello ");
    io.peer_send(peer, 40, "world.this is never answered");

    var closed_at = -1;
    io.serve() { io, ev => {
        shout_event(lib, io, ev);
        match ev {
            Closed c => { closed_at = io.now_ms(); },
            _ => {},
        }
        kit::stop_after(io, ev, 200);           // stop at the first Tick at or after 200 ms
    } };

    kit::check(io.peer_received(peer) == "HELLO WORLD", "the peer got the answer, and nothing after the '.'");
    kit::check(closed_at == 50, "the library closed the link when the '.' arrived, 50 ms in");
    kit::check(io.peer_saw_eof(peer), "the peer saw the end of the stream");
    kit::check(lib.links == 0 && lib.bytes == 11, "the library's own counts are right");
    kit::check(io.now_ms() == 200, "200 ms of the loop's clock passed, and no real time to speak of");
    kit::finish();
}
```

Run it with `goose run tests/unit/library_example_test.goose`, or run every test with
`tests/run_tests.sh` (`just test`). `kit` is the test support in `tests/support/kit.goose`: a
failure counter, and a recorder that keeps every event a handler saw so a test can check the
order, the times and the bytes afterwards.

### Two ways to get the other end of a link

| The other end is | How | Use it to test |
|---|---|---|
| a scripted peer | `add_peer`, then the `peer_` functions below | one library against exact input and timing |
| another library on the same loop | one `listen`s, the other `dial`s the same address | a client and a server against each other |

A `dial` goes to a listener on the loop if one has the address, otherwise to the first scripted
peer still waiting at it, otherwise it fails with `ConnectFailed`, kind `Refused`. Addresses are numeric,
`ip:port` or `[ip6]:port` with hexadecimal groups, as the contract requires (text with an IPv4 tail, such as
`::ffff:192.0.2.1`, is `BadAddress` here, and a portable library does not use it); nothing is resolved and no real socket is
opened, so any address will do. A listener on `0.0.0.0` or `[::]` takes dials to any address of
its family on its port.

Two listeners whose addresses overlap cannot coexist: a `listen` on the same family and port as an
active listener or a `hold`, when either address is the wildcard or the two are equal, fails with
`AddressInUse`, whichever came first, so a dial never has two listeners to choose from. IPv4 and
IPv6 are separate families here, and a stopped listener does not conflict. `listen` on port 0
chooses a free port from 49152 to 65535 (it wraps inside that range and fails with `NoResources`
only when every port is in use); accepted links report a remote port in the same range.

### Scripted peers

A peer plays one connection. It gets its link in one of two ways, then does its steps in the
order they were added. Each step has a delay in milliseconds: the step runs that long after the
step before it finished, or after the peer's link opened, whichever is later.

| Function | What the peer does |
|---|---|
| `add_peer() -> Peer` | A new peer with no link and no steps. |
| `peer_accept(p, address)` | Waits at the address and accepts one dial to it. |
| `peer_refuse(p, address)` | Waits at the address and refuses one dial to it: the dial fails with `ConnectFailed`. |
| `peer_connect(p, address, after_ms)` | Step: connects to a listener on the loop. |
| `peer_send(p, after_ms, bytes)` | Step: sends the bytes. More than fits goes out as the library reads, and later steps wait for it. |
| `peer_stop_reading(p, after_ms)` | Step: stops reading, so the library's sends fill the link's bound and return `Full`. |
| `peer_resume_reading(p, after_ms)` | Step: reads again. |
| `peer_shutdown(p, after_ms)` | Step: finishes sending and keeps receiving (a half-close). |
| `peer_close(p, after_ms)` | Step: closes. The library reads what the peer sent and then sees a clean end. |
| `peer_abort(p, after_ms)` | Step: aborts. The library's link ends with `PeerReset` and what it had not read is lost. |

What the test reads back:

| Function | Result |
|---|---|
| `peer_received(p) -> u8[>..]` | Every byte the library sent to the peer and the peer read, in order. |
| `peer_connected(p) -> bool` | The peer's link is open now. |
| `peer_saw_eof(p) -> bool` | The library finished sending: it closed the link or called `shutdown_write`. |
| `peer_saw_reset(p) -> bool` | The library reset the link. |
| `peer_closed(p) -> bool` | The peer's link has ended, or its connect failed, or it refused its dial. |

For a second connection to the same address, add a second peer: dials meet the waiting peers in
the order they were added. That is how a reconnect is scripted: the first peer refuses or aborts,
the second accepts.

A peer reads everything sent to it unless told to stop. It hangs up by itself once the library
has finished sending and the peer has no steps left, so a test does not need a closing step for
every peer.

`stop` waits for a peer to read what the library sent it and to see the end of the library's
stream, so after `serve` returns `peer_received` holds the whole reply and `peer_saw_eof` is true
(`peer_reads_before_stop_returns` in `tests/unit/memory_peers_test.goose` is the test). It does not
wait for a peer's later steps or for a peer told to stop reading, so a test that needs a peer to
read more than that adds the step and a deadline for it, and does not stop the loop before then.

### The clock

`now_ms` starts at 0. The loop delivers everything that is due and then moves the clock straight
to the next moment something is due: the next regular `Tick` (every `cfg.tick_ms`), the earliest
`tick_by`, a dial's connect time, a peer's next step, or the end of a grace period. Nothing
sleeps and the application's clock is never read.

Everything that happens in answer to an event happens at the same millisecond. Only when the
loop stays busy for `cfg.passes_per_ms` passes in a row without the clock moving does the clock
advance by 1 ms, so a library that keeps the loop busy forever still sees time pass and still
reaches its own timeouts and the time limit.

### Configuration

Set these on `io.cfg` before the first `listen`, `dial`, `add_peer` or `serve`.

| Field | Default | Meaning |
|---|---|---|
| `link_buffer` | 65536 | Most bytes held unsent for one link. What a library may send is this minus what the other end has not read yet. |
| `max_send` | 65536 | Largest single send. At least 4096, at most `link_buffer`. |
| `read_chunk` | 16384 | Most bytes in one `Data` event. Set it small to check that a library copes with input split anywhere. |
| `max_links` | 256 | Link ends of libraries on this loop at once, not connections: a pair joined inside the loop uses two, and a link to a scripted peer one. A dial beyond it fails with `ConnectFailed`, kind `NoResources`. |
| `max_listeners` | 4096 | Listeners ever created on the loop. A handle is never used again, so they can run out; `listen` then fails with `NoResources`. |
| `connect_timeout_ms` | 5000 | What a `connect_ms` of 0 means in `dial`. |
| `tick_ms` | 100 | The period of the regular `Tick`. A value below 1 is raised to 1. |
| `time_limit_ms` | 600000 | See "Limits". |
| `exit_on_time_limit` | true | See "Limits". |
| `passes_per_ms` | 64 | See "The clock". A value below 1 is raised to 1. |

A setting that would stop the loop making progress is raised to the smallest value that does not
(`tick_ms`, `passes_per_ms`, `max_send`, `link_buffer`, `read_chunk`); the other settings only make
things fail sooner, so none can make `serve` run for ever.

### Making things go wrong

| Function | Effect |
|---|---|
| `hold(address)` | `listen` on the address fails with `AddressInUse`, as if another process held it. |
| `silent(address)` | A dial to the address never answers and ends only when its connect time passes, with kind `TimedOut`. |
| `fail_dials(address, kind)` | A dial to the address fails at once with `ConnectFailed` of that kind, whatever listens there: `Unreachable`, `Denied`, `NoResources`, `Other`. |
| `close_with_reason(link, why)` | Closes a library's link as an event loop may on its own policy, with any reason: `IdleTimeout`, `Error`, `LoopSpecific { code }`. The other end sees a clean end. |
| `peer_refuse`, `peer_abort`, `peer_stop_reading` | See "Scripted peers". |

And for checking afterwards:

| Function | Result |
|---|---|
| `stored_bytes(link) -> i64` | Bytes accepted from the link that the other end has not read. Never more than `cfg.link_buffer`. |
| `passes() -> i64` | Passes `serve` has made. An idle loop makes one per `Tick`, so a test can check that waiting costs nothing. |
| `hit_time_limit() -> bool` | See "Limits". |

### Limits

- **A test cannot hang.** If `serve` has not returned after `cfg.time_limit_ms` of the loop's
  clock, the event loop prints a message naming the limit and exits with status 1. With
  `cfg.exit_on_time_limit = false`, `serve` returns instead and `hit_time_limit()` is true.
  The usual cause is a test that never calls `stop`, or a link that nothing closes.
  `tests/unit/memory_runaway_mustfail.goose` shows the failure.
- **`serve` returns** after `stop` once no link of a library is left. Scripted peers do not keep
  it running. A test usually stops at a time, as `kit::stop_after(io, ev, 200)` does, or when the
  library reaches the state under test.
- **It is not a network.** Bytes arrive in the pass after they were sent, complete and in order.
  There is no delay, loss or reordering to script, apart from what peers do with their steps.
- **Sending to an end that has gone** returns `Sent`; the bytes are lost and the link then ends
  with `PeerReset`. A real event loop behaves the same way one round trip later.
- **Host names** do not resolve: a dial to one fails with `ConnectFailed`, kind `BadAddress`, as the contract says.
- **Tables grow as needed.** The event loop uses growable arrays, so it has no fixed table sizes to
  configure; `max_links` and `link_buffer` are the bounds a library can observe.

Passing on this event loop does not make a library correct on every event loop: a real event loop may
split `Data` differently, refuse sends at other moments, and close links for its own reasons.
A library that follows [contract.md](contract.md) and passes its tests here with a small
`read_chunk` and a small `link_buffer` has covered what the contract lets an event loop vary.
