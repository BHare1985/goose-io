// A line server: a library on the goose-io contract that answers newline-delimited requests.
//
// Needs: core and half-close (the line server keeps a link open after the peer finishes sending, to answer what it
// has read, so it calls set_keep_open_on_eof). It fails to build on a loop that lacks half-close.
//
// It imports the contract and nothing else, so it runs on every event loop that passes the conformance suite.
// It shows the shape of a library (docs/libraries.md): a state struct, one event entry point that says whether
// it handled the event, a `LinkMap` to find a connection from the link of an event, `Full` and `Writable` for
// backpressure, and what to do while the loop is stopping.
//
// The server reads lines. The application takes each request with `take_request` and answers it with `reply`:
//
//     io.serve() { io, ev =>
//         server.server_event(io, ev);
//         loop {
//             var line: u8[>..] = [];
//             let r = server.take_request(io, line);
//             if !r.found { break; }
//             server.reply(io, r, "echo ", line);
//         }
//     };
//
// A connection has one request in the application's hands at a time: later requests wait in the connection's
// input buffer, which is what keeps replies in the order of the requests. Input and output buffers are fixed in
// size, so a peer that sends faster than it is answered, or reads slower than it is answered, is held back by
// `pause_reading` and by `Full` and is never allowed to make the server grow.
namespace lineserver;
import std;
import goose_io;

let LINE_MAX = 2048;        // a longer line closes the connection
let IN_CAP = 4096;          // input held per connection
let OUT_CAP = 32768;        // output held per connection
let PAUSE_AT = 3072;        // reading is paused above this much unread input

struct Conn {
    link:    goose_io::Link = goose_io::Link { .. },
    in_use:  bool           = false,
    busy:    bool           = false,        // a request was taken and has not been answered
    eof:     bool           = false,        // the peer has finished sending
    closing: bool           = false,        // close was called
    paused:  bool           = false,        // reading is paused
    sent:    i64            = 0,            // bytes of `out` the event loop has taken
    in_buf:  u8[..4096]     = [],
    out:     u8[..32768]    = [],
}

// A request taken from the server, to be answered with `reply`.
struct Request { found: bool = false, conn: i64 = 0, link: goose_io::Link = goose_io::Link { .. } }

// Where a link's connection is in the server's table. A connection holds about 36 KB of buffers, so the table of
// connections stays compact (one entry for each open connection) and the `LinkMap` holds only this index: its
// memory is the event loop's peak slot count times a few bytes and not times a connection's size.
struct Ref { index: i64 = 0 }

// doc:begin state
root struct LineServer {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    open:     i64                    = 0,
    fulls:    i64                    = 0,   // how many sends were refused with Full
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},         // the connection of a link
    conns:    Conn[>..]              = [],
    free:     i64[>..<]              = [],
}
// doc:end state

// Listens on `address`; it handles the links that listener accepts. False if the listen failed.
fn start<Io>(s: LineServer&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    s.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn open_connections(s: LineServer&) -> i64 { s.open }

// How many sends were refused with Full so far.
fn full_count(s: LineServer&) -> i64 { s.fulls }

// The connection a link event belongs to, or -1 when the link is not one of this server's: a stale link, another
// library's link and a link that was dropped all find nothing in the map.
fn _conn_of(s: LineServer&, link: goose_io::Link) -> i64 {
    let r .= s.refs.find(link);
    guard r != null else { return -1; }
    let i = r.index;
    guard i < s.conns.len && s.conns[i].in_use && goose_io::same(s.conns[i].link, link) else { return -1; }
    return i;
}

fn _find_newline(b: const u8[:]) -> i64 {
    for c, i in b { if c == '\n' { return i; } }
    return -1;
}

fn _out_pending(c: Conn&) -> bool { c.out.len > c.sent }

// doc:begin flush
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
// doc:end flush
fn _has_line(c: Conn&) -> bool { _find_newline(c.in_buf[..]) >= 0 }

// Closes the connection when the peer is done and nothing is owed to it.
fn _finish_if_done<Io>(s: LineServer&, io: Io&, i: i64) {
    let c .= s.conns[i];
    if c.in_use && !c.closing && c.eof && !c.busy && !_out_pending(c) && !_has_line(c) {
        c.closing = true;
        io.close(c.link);
    }
}

fn _resume_if_room<Io>(s: LineServer&, io: Io&, i: i64) {
    let c .= s.conns[i];
    if c.in_use && c.paused && c.in_buf.len <= PAUSE_AT {
        c.paused = false;
        io.pause_reading(c.link, false);
    }
}

fn _on_opened<Io>(s: LineServer&, io: Io&, link: goose_io::Link) {
    var i = 0;
    if s.free.len > 0 {
        i = s.free[s.free.len - 1];
        s.free.pop();
    } else {
        i = s.conns.len;
        s.conns.push(Conn { .. });
    }
    let c .= s.conns[i];
    c.link = link;
    c.in_use = true;
    c.busy = false;
    c.eof = false;
    c.closing = false;
    c.paused = false;
    c.sent = 0;
    c.in_buf.clear();
    c.out.clear();
    s.open++;
    s.refs.put(link, Ref { index: i });
    // doc:begin keep_open
    io.set_keep_open_on_eof(link, true);      // in the handler of Opened: the peer finishing is then PeerEof, not Closed
    // doc:end keep_open
}

fn _on_data<Io>(s: LineServer&, io: Io&, i: i64, bytes: const u8[:]) {
    let c .= s.conns[i];
    if c.closing { return; }
    if c.in_buf.len + bytes.len > IN_CAP {
        c.closing = true;                     // more than a connection may hold: the peer is not speaking this protocol
        io.close(c.link);
        return;
    }
    c.in_buf.append(bytes);
    if !_has_line(c) && c.in_buf.len > LINE_MAX {
        c.closing = true;
        io.close(c.link);
        return;
    }
    if c.in_buf.len > PAUSE_AT && !c.paused {
        c.paused = true;
        io.pause_reading(c.link, true);
    }
}

// The next request that is ready: a connection with nothing in the application's hands, nothing waiting to be
// sent, and a whole line. The line is appended to `line` without its end of line. Not found when there is none.
fn take_request<Io>(s: LineServer&, io: Io&, line: u8[>..]&) -> Request {
    for i in s.conns.len {
        let c .= s.conns[i];
        if c.in_use && !c.busy && !c.closing && !_out_pending(c) {
            let k = _find_newline(c.in_buf[..]);
            if k >= 0 {
                let end = if k > 0 && c.in_buf[k - 1] == '\r' { k - 1 } else { k };
                line.append(c.in_buf[..end]);
                let rest = c.in_buf.len - (k + 1);
                if rest > 0 { c.in_buf[..rest].move_from(c.in_buf[k + 1..k + 1 + rest]); }
                c.in_buf.resize(rest, 0);
                c.busy = true;
                s._resume_if_room(io, i);
                return Request { found: true, conn: i, link: c.link };
            }
        }
    }
    return Request { .. };
}

// Answers a request: `text` and an end of line are queued and sent. False if the connection has gone (a late
// answer is dropped) or the answer does not fit the connection's output buffer (the connection is closed).
fn reply<Io>(s: LineServer&, io: Io&, r: Request, text: const u8[:]) -> bool {
    guard r.found && r.conn < s.conns.len else { return false; }
    let c .= s.conns[r.conn];
    guard c.in_use && c.busy && goose_io::same(c.link, r.link) else { return false; }
    if c.out.len + text.len + 1 > OUT_CAP {
        c.closing = true;
        io.close(c.link);
        return false;
    }
    c.out.append(text);
    c.out.push('\n');
    c.busy = false;
    s._flush(io, r.conn);
    s._finish_if_done(io, r.conn);
    return true;
}

// doc:begin draining
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
// doc:end draining
// doc:begin entry
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
        Input i => { return false; },
        Expired x => { return false; },
        Woken w => { return false; },
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
        // doc:begin peer_eof
        PeerEof e => {
            let i = s._conn_of(e.link);
            guard i >= 0 else { return false; }
            s.conns[i].eof = true;                // no more requests will come; answer what was read, then close
            s._finish_if_done(io, i);
            return true;
        },
        // doc:end peer_eof
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
// doc:end entry
