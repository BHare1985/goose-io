// An echo server: the smallest library on the goose-io contract, and the one to read first. It answers every byte a
// peer sends with the same byte.
//
// Needs: core only. It runs on every event loop.
//
// It imports the contract and nothing else, so it does not know which event loop it runs on. The application
// passes it every event, and the server says whether the event was its own:
//
//     var echo = echo::Echo { .. };
//     echo.start(io, "0.0.0.0:7", 1);               // listen on port 7; its links carry tag 1
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

root struct Echo {
    tag:     u16       = 0,
    refused: i64       = 0,             // how many sends were refused with Full
    conns:   Conn[>..] = [],
    free:    i64[>..<] = [],
}

// Listens on `address`; the links it accepts carry `tag`. False if the listen failed.
fn start<Io>(e: Echo&, io: Io&, address: const u8[:], tag: u16) -> bool {
    e.tag = tag;
    let l, err = io.listen(address, tag);
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

// How many sends were refused with Full so far.
fn refused_count(e: Echo&) -> i64 { e.refused }

// The connection a link event belongs to, or -1: the user value is the index, and the link must match.
fn _conn_of(e: Echo&, user: u32, link: goose_io::Link) -> i64 {
    guard user < e.conns.len else { return -1; }
    let c .= e.conns[user];
    guard c.in_use && goose_io::same(c.link, link) else { return -1; }
    return user;
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

// The library's one entry point: true if the event was for this server, false if it is another library's (or a
// Tick or PassEnd, which every library is offered).
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
            if o.tag != e.tag { return false; }
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
            io.set_user(o.link, i as u32);
            return true;
        },
        Data d => {
            if d.tag != e.tag { return false; }
            let i = e._conn_of(d.user, d.link);
            if i >= 0 { e._on_data(io, e.conns[i], d.bytes); }
            return true;
        },
        Writable w => {
            if w.tag != e.tag { return false; }
            let i = e._conn_of(w.user, w.link);
            if i >= 0 { e._send_held(io, e.conns[i]); }
            return true;
        },
        PeerEof f => {
            return f.tag == e.tag;
        },
        Closed x => {
            if x.tag != e.tag { return false; }
            let i = e._conn_of(x.user, x.link);
            if i >= 0 {
                e.conns[i].in_use = false;
                e.free.push(i);
            }
            return true;
        },
    }
}
