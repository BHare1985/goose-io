// An echo server: the smallest library on the goose-io contract, and the one to read first. It answers every byte a
// peer sends with the same byte.
//
// Needs: core only. It runs on every event loop.
//
// It imports the contract and nothing else, so it does not know which event loop it runs on. The application
// passes it every event, and the server says whether the event was its own:
//
//     var echo = echo::Echo { .. };
//     echo.start(io, "0.0.0.0:7");                  // listen on port 7; it handles the links that listener accepts
//     io.serve() { io, ev => echo.echo_event(io, ev); };
//
// A peer that sends faster than it reads is held back: when a send is refused (`Full`) the server keeps the bytes,
// stops reading from that peer with `pause_reading`, and carries on when the loop says `Writable`.
namespace echo;
import std;
import goose_io;

let HOLD = 16384;       // bytes kept for a peer that is not reading (two reads: one more Data can follow pause_reading)

struct Conn {
    link:   goose_io::Link = goose_io::Link { .. },
    in_use: bool           = false,
    held:   u8[..16384]    = [],        // what the event loop refused, waiting for Writable
}

// Where a link's connection is in the server's table. A connection holds 16 KB, so the table of connections stays
// compact and the `LinkMap` holds only the index.
struct Ref { index: i64 = 0 }

root struct Echo {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    refused:  i64                    = 0,    // how many sends were refused with Full
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
    free:     i64[>..<]              = [],
}

// Listens on `address`; it handles the links that listener accepts. False if the listen failed.
fn start<Io>(e: Echo&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    e.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

// How many sends were refused with Full so far.
fn refused_count(e: Echo&) -> i64 { e.refused }

// The connection a link event belongs to, or -1 when the link is not one of this server's.
fn _conn_of(e: Echo&, link: goose_io::Link) -> i64 {
    let r .= e.refs.find(link);
    guard r != null else { return -1; }
    let i = r.index;
    guard i < e.conns.len && e.conns[i].in_use && goose_io::same(e.conns[i].link, link) else { return -1; }
    return i;
}

// Gives back what the event loop will take now. A refusal waits for Writable.
fn _send_held<Io>(e: Echo&, io: Io&, c: Conn&) {
    if c.held.len == 0 { return; }
    let status = io.send(c.link, c.held[..]);
    if status == goose_io::SendStatus.Sent {
        c.held.clear();
        io.pause_reading(c.link, false);
    } else if status != goose_io::SendStatus.Full {
        io.close(c.link);       // the link is going, or the bytes can never be sent in one piece
    }
}

// doc:begin on_data
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
// doc:end on_data

// The library's one entry point: true if the event was for a link of this server, false if it is another library's (or a
// Tick or PassEnd, which every library is offered). An accepted link is this server's when `Opened` names its listener.
fn echo_event<Io>(e: Echo&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => {
            if io.draining() {
                for c in e.conns { if c.in_use { io.close(c.link); } }
            }
            return false;
        },
        PassEnd => { return false; },
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, e.listener) else { return false; }
            var i = 0;
            if e.free.len > 0 {
                i = e.free[e.free.len - 1];
                e.free.pop();
            } else {
                i = e.conns.len;
                e.conns.push(Conn { .. });
            }
            let c .= e.conns[i];
            c.link = o.link;
            c.in_use = true;
            c.held.clear();
            e.refs.put(o.link, Ref { index: i });
            return true;
        },
        Data d => {
            let i = e._conn_of(d.link);
            guard i >= 0 else { return false; }
            e._on_data(io, e.conns[i], d.bytes);
            return true;
        },
        Writable w => {
            let i = e._conn_of(w.link);
            guard i >= 0 else { return false; }
            e._send_held(io, e.conns[i]);
            return true;
        },
        PeerEof f => {
            return e._conn_of(f.link) >= 0;
        },
        Closed x => {
            let i = e._conn_of(x.link);
            guard i >= 0 else { return false; }
            e.conns[i].in_use = false;
            e.free.push(i);
            e.refs.drop(x.link);
            return true;
        },
    }
}
