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
stream means it is done, `Tick` and `tick_by` replace `PassEnd` for a library that does not batch. A library that needs a group
fails to build on an event loop without it, naming the operation. `examples/lineclient/` needs only the core and its
tests run on `tests/support/core_only.goose`; `examples/lineserver/` answers after the peer has finished sending, so it needs half-close.

An event the loop never delivers is simply never handled: the `PeerEof` and `PassEnd` arms of the example libraries
are never run on a loop without those groups.

## The shape of a library

A library is a **state struct** and **functions generic over the event loop**, with one **event entry point** that
says whether the event was its own. It imports the contract and nothing that names an event loop (the check is
`tests/examples/imports_test.sh`), so one source runs on every event loop that passes the conformance suite.

The state is one struct that the application owns: a local or a global variable, passed by reference. It holds the
library's listener or its pool of links, a `LinkMap` that finds a connection from the link of an event, and its buffers. Buffers have fixed sizes in these examples, so
a peer that is too fast, too slow or silent cannot make the library grow; a library that needs more may use
growable arrays, with the one rule of Goose that an array element cannot itself be resizable.

<!-- excerpt: examples/lineserver/server.goose#state -->
```goose
root struct LineServer {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    open:     i64                    = 0,
    fulls:    i64                    = 0,   // how many sends were refused with Full
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},         // the connection of a link
    conns:    Conn[>..]              = [],
    free:     i64[>..<]              = [],
}
```

The entry point takes the library, the event loop and the event. It returns true when the event was for the
library and false when it is not: another library's, or a `Tick` or `PassEnd`, which every library is offered and
none owns.

<!-- excerpt: examples/lineserver/server.goose#entry -->
```goose
// The library's one entry point: true if the event was for a link of this server, false if it is another library's
// (or a Tick or PassEnd, which every library is offered). An accepted link is this server's when `Opened` names its
// listener; every later event is its own when the map has the link.
fn server_event<Io>(s: LineServer&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => {
            if io.draining() { s._close_idle(io); }
            return false;
        },
        PassEnd => { return false; },
        Opened e => {
            guard goose_io::is_listener(e.listener) && goose_io::same(e.listener, s.listener) else { return false; }
            s._on_opened(io, e.link);
            return true;
        },
        Data e => {
            let i = s._conn_of(e.link);
            guard i >= 0 else { return false; }
            s._on_data(io, i, e.bytes);
            return true;
        },
        Writable e => {
            let i = s._conn_of(e.link);
            guard i >= 0 else { return false; }
            s._flush(io, i);
            s._finish_if_done(io, i);
            return true;
        },
        PeerEof e => {
            let i = s._conn_of(e.link);
            guard i >= 0 else { return false; }
            s.conns[i].eof = true;
            s._finish_if_done(io, i);
            return true;
        },
        Closed e => {
            let i = s._conn_of(e.link);
            guard i >= 0 else { return false; }
            s.conns[i].in_use = false;
            s.open--;
            s.free.push(i);
            s.refs.drop(e.link);
            return true;
        },
    }
}
```

### How an event finds its state

Nothing is attached to a link: an event carries its **link**, and the library keeps its own state keyed by it. A
library recognises its events by what it already holds. A **dialled** link is the one `dial` returned, which the library
put in its table before any event about it (so a dial that fails at once finds its state too, because every event is
delivered after the handler that called `dial` has returned). An **accepted** link is one whose `Opened` names a
listener the library started: the library compares `e.listener` with its own, as a ZeroMQ program compares the socket
`zpoller_wait` returned with its frontend. Every **later** event is one whose link the library has state for. For any
other link the library returns "not handled", and the application offers the event to the next library: a library
claims an event only when it owns the link, and does none of its handling for a link it does not know.

`goose_io::LinkMap<T>` is the table for this. `put(link, value)` stores a value, `find(link)` returns a reference to it or
nothing, `has(link)` asks, and `drop(link)` empties the entry. A stale link, another library's link, a link never put and a
dropped link all find nothing, because the generation of the link is stored beside the value. Both examples use it.

The `server_event` of `examples/lineserver` above is the whole pattern: `Opened` compares `e.listener` with the server's listener and puts
the link in the map; `Data`, `Writable` and `PeerEof` look the link up and return `false` when it is not found; `Closed` looks it up, releases
the connection and calls `s.refs.drop(e.link)` (the handle is valid until that handler returns).

A dialled link's `Opened` finds the entry the library put when `dial` returned: the library does not `put` it again, which
would overwrite what it had set up. A library that has several listeners compares `e.listener` with each; a library that both
accepts and dials uses one map for both. Use one map only with the links of one event loop (two loops can issue equal
slot and generation pairs).

#### Choosing a table

`LinkMap` is flat: it holds an entry (a generation and a value) for each slot up to the highest one the library has used, so its
memory is **the event loop's peak slot count times the size of the entry**. Slots are dense on every event loop (a freed slot
is reused before a new one is issued), so that number is the greatest number of links valid at once on the loop, which counts every library's links, not
only yours. For small state this is nothing: 1,024 slots of 512 bytes is about half a megabyte, and a lookup costs the same as
a table you would write by hand (`bench/README.md`, measured at its largest use too). For **large state** (the example
servers keep 16 to 36 KB of buffers for each connection) do not put the state in the map: keep the records in a compact table of
your own, one for each open connection, and put only the index in the map (`LinkMap<Ref>` with `struct Ref { index: i64 }`),
as `examples/lineserver` and `examples/echo` do. The map then costs a few bytes a slot. A library may also keep its state
any other way, or with another layout (the benchmark has a compact table that stores values only for the links a library owns),
because the contract guarantees the identity and lifetime of a link and not the table; the laws a table must obey are in
`tests/unit/link_map_test.goose`, written so that another table can be run through them.

### The end of the loop

- **Do not count on delivery at the end of the grace period.** When `stop`'s grace period ends the event loop may discard bytes
  you were told were `Sent`, so a protocol that needs the peer to have received something has the peer say so. A link you had
  closed before the end of the grace period ends with `Local`, not `Shutdown`, whether you closed it before or after `stop`.
- **After `serve` has returned the loop is finished.** Every operation does nothing and returns at once: `send` returns `Closed`,
  `listen` fails, and `dial` returns the invalid link, so check `goose_io::is_valid` on a link from a `dial` that may be made
  after `serve` could have returned. A second `serve` returns at once without calling your handler.
- **A loop belongs to the thread that serves it**: set it up (`listen`, `dial`) and call `serve` on one thread, and do not use
  one loop from two threads.

### Keep-open and the end of a send

- **Call `set_keep_open_on_eof(link, true)` in the handler of the link's `Opened`**, or before it for a link you dialled
  (right after `dial` returns, while it is dialling). A call made later, from the handler of a `Data` for instance, has no
  effect even if the peer has not finished: the contract fixes this window so that every event loop answers the same way
  (`examples/lineserver` calls it in the handler of `Opened`).
- **A `Closed` result from `send` is final for sending**: drop the send queue for that link, and expect no `Writable`. It does
  not mean no more `Data`: if you called `shutdown_write` the link goes on receiving until its `Closed` event, and if you
  did not, the event loop is ending the link and its `Closed` follows with no further call.

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

The application is the only code that names an event loop. It runs the loop and hands each event to
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

struct Link { open: bool = false }

struct Shout {
    listener: goose_io::Listener      = goose_io::Listener { .. },
    links:    i64                     = 0,
    bytes:    i64                     = 0,
    conns:    goose_io::LinkMap<Link> = goose_io::LinkMap<Link> {},        // the library's state, found by the event's link
}

// Returns false for an event that belongs to another library: an accepted link is ours when `Opened` names our
// listener, and every later event is ours when we have state for its link.
fn shout_event<Io>(lib: Shout&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened e => {
            guard goose_io::is_listener(e.listener) && goose_io::same(e.listener, lib.listener) else { return false; }
            lib.conns.put(e.link, Link { open: true });
            lib.links++;
        },
        Data d => {
            guard lib.conns.has(d.link) else { return false; }
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
        Closed e => {
            guard lib.conns.has(e.link) else { return false; }
            lib.links--;
            lib.conns.drop(e.link);
        },
        _ => { return false; },
    }
    return true;
}

// --- the test ------------------------------------------------------------------------------------

fn main() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.read_chunk = 4;                      // deliver in small pieces: the library must not care
    var lib = Shout { .. };
    let listener, err = io.listen("127.0.0.1:7000");
    kit::check(!goose_io::failed(err), "listen");
    lib.listener = listener;

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

### A path as an address

A library that wants a Unix socket passes `unix:/path` (or `unix:///path`, the same path, as Docker, gRPC and Redis configuration write it) where it would pass a numeric address, to `dial` or `listen`, and
nothing else changes. The in-memory loop supplies the unix group: a path is the name of an endpoint, a listener holds
it, a dial reaches it, and a scripted peer can wait at it as it waits at an address. A path has no port
(`listener_port` is 0) and no peer address text. Set `io.cfg.unix_paths = false` to see a library meet a loop without
the group: every path is `BadAddress`.

<!-- excerpt: tests/examples/unix_dial_test.goose#unix_peer -->
```goose
fn dials_a_path<Io>(io: Io&) {
    var log = kit::Log { .. };
    let db = io.add_peer();
    io.peer_accept(db, "unix:/var/run/postgresql/.s.PGSQL.5432");
    io.peer_send(db, 5, "ready");
    let link = io.dial("unix:/var/run/postgresql/.s.PGSQL.5432", 0);
    io.serve() { io, ev => on_event(log, io, ev); };
    kit::check(kit::data_of(log, link) == "ready", "the peer at the path answers");
    kit::check(io.peer_received(db) == "hello", "and reads what the library sent");
}
```

### Protocol URLs are the library's

`postgres://`, `mysql://` and `redis://` are not addresses. They carry credentials, a database name, a TLS choice and
rules for where a socket is, none of which an event loop knows. A library reads its own URL and passes `dial` an
address: `unix:/path`, `unix:///path` (the same path) or a numeric `ip:port`. Text that is none of these is `BadAddress`,
as a host name is, since the contract does no name resolution.

| The library is given | It passes to `dial` |
|---|---|
| a PostgreSQL host setting of `/run/postgresql`, port 5432 | `unix:/run/postgresql/.s.PGSQL.5432` |
| `redis+unix:///run/redis.sock` | `unix:///run/redis.sock` |
| a MySQL `socket=/run/mysqld/mysqld.sock` | `unix:/run/mysqld/mysqld.sock` |
| `redis://10.0.0.5:6379` | `10.0.0.5:6379` |
| `redis://cache.internal:6379` | its own lookup first; the event loop never resolves a name |

What the system reports for a path that fails (no file, nobody listening, no permission) arrives as the kinds the
contract already has, `Refused`, `Denied`, `NoResources` or `Other`. There is no kind for a Unix socket.

### Moving from 0.2

Version 0.3 removes the tag and the user value. A library or an event loop moves in these steps; each is a compile error
until done, and the error names the operation.

1. **Event loop:** stop taking `tag` in `listen` and `dial`; drop `tag` and `user` from the five link events; drop `set_user` and
   `user`; take slots from a free list before extending, so that slots are dense.
2. **Library:** replace the table indexed by the user value with a `LinkMap` keyed by the link (holding the state, or an index into a
   compact table for large state); delete the `tag` field and every `if e.tag != s.tag`; in `Opened` decide ownership by `e.listener`
   (an accepted link) or by `has(e.link)` (a dialled link); return "not handled" from every arm whose link the library does not own;
   in `Closed`, call `drop`.
3. **Application:** stop assigning tags to libraries.

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
| `unix_paths` | true | Supply the unix group. With false, `unix:/path` is refused with `BadAddress`, as by a loop without the group. |

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
- **A slot is retired, not wrapped.** When the link holding a slot's last generation (`0xffffffff`) has had its
  `Closed` delivered, the loop never issues that slot again, so no slot and generation pair is issued twice. It does not
  lower `cfg.max_links`, which counts link ends. A test shows it without 2^32 reuses by setting a free slot's next
  generation with `io.age_slot(slot, next_gen)`, a scripting call that is not part of the contract.
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
