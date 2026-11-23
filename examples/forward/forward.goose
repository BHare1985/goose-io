// A forwarder: it accepts connections on a front address, dials a backend for each, and carries the bytes both ways.
// It shows how a library uses a capability the loop may or may not supply.
//
// Needs: core only. It runs on every event loop.
// Uses if supplied: relay (bytes pass in the loop, not through this library).
//
// On a loop that supplies relay the two links are handed to the loop, and the library sees no `Data` for them. On a
// loop that does not, the library copies: it sends what arrives on one link to the other, stops reading with
// `pause_reading` when a send is refused (`Full`), and carries on when the loop says `Writable`. The choice is made
// when the library is built, with `const if` on the answer of `goose_io::has_relay`, so a loop without relay never
// compiles the call to `relay`. The application uses it like the echo server:
//
//     var f = forward::Forward { .. };
//     f.start(io, "0.0.0.0:8080", "10.0.0.5:80", 5000);     // front address, backend address, connect timeout
//     io.serve() { io, ev => f.forward_event(io, ev); };
namespace forward;
import std;
import goose_io;

let HOLD = 16384;       // bytes kept for a link that is not reading

struct Side {
    link:   goose_io::Link = goose_io::Link { .. },
    in_use: bool           = false,
    up:     bool           = false,         // the link is open (a dial in progress is not)
    peer:   i64            = -1,            // the other side of the connection, an index in `sides`
    held:   u8[..16384]    = [],            // what the event loop refused to take for this link, waiting for Writable
}

struct Ref { index: i64 = 0 }

root struct Forward {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    backend:  u8[..64]               = [],
    connect_ms: i64                  = 5000,
    relayed:  i64                    = 0,    // connections handed to the loop with relay
    copied:   i64                    = 0,    // connections whose bytes pass through the library
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    sides:    Side[>..]              = [],
    free:     i64[>..<]              = [],
}

// Listens on `front`; each accepted link gets a dial to `backend`. False if the listen failed.
fn start<Io>(f: Forward&, io: Io&, front: const u8[:], backend: const u8[:], connect_ms: i64) -> bool {
    let l, err = io.listen(front);
    f.listener = l;
    f.backend.clear();
    f.backend.append(backend);
    f.connect_ms = connect_ms;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

// How many connections were handed to the loop, and how many the library copies.
fn relayed_count(f: Forward&) -> i64 { f.relayed }
fn copied_count(f: Forward&) -> i64 { f.copied }

fn _side_of(f: Forward&, link: goose_io::Link) -> i64 {
    let r .= f.refs.find(link);
    guard r != null else { return -1; }
    let i = r.index;
    guard i < f.sides.len && f.sides[i].in_use && goose_io::same(f.sides[i].link, link) else { return -1; }
    return i;
}

fn _new_side(f: Forward&, link: goose_io::Link, up: bool) -> i64 {
    var i = 0;
    if f.free.len > 0 {
        i = f.free[f.free.len - 1];
        f.free.pop();
    } else {
        i = f.sides.len;
        f.sides.push(Side { .. });
    }
    let s .= f.sides[i];
    s.link = link;
    s.in_use = true;
    s.up = up;
    s.peer = -1;
    s.held.clear();
    f.refs.put(link, Ref { index: i });
    return i;
}

// Gives a link what the event loop will take now. A refusal waits for Writable; when all is sent the other side is read again.
fn _send_held<Io>(f: Forward&, io: Io&, s: Side&) {
    if s.held.len == 0 || !s.up { return; }
    let status = io.send(s.link, s.held[..]);
    if status == goose_io::SendStatus.Sent {
        s.held.clear();
        if s.peer >= 0 { io.pause_reading(f.sides[s.peer].link, false); }
    } else if status != goose_io::SendStatus.Full {
        io.close(s.link);
    }
}

// doc:begin copy
// Bytes arrived on a link: send them to the other side, or keep them and stop reading when the loop is full.
fn _copy<Io>(f: Forward&, io: Io&, from: Side&, bytes: const u8[:]) {
    guard from.peer >= 0 else { return; }
    let to .= f.sides[from.peer];
    if to.held.len == 0 && to.up {
        let status = io.send(to.link, bytes);
        if status == goose_io::SendStatus.Sent { return; }
        if status != goose_io::SendStatus.Full { io.close(to.link); return; }
    }
    if to.held.len + bytes.len > HOLD { io.close(to.link); io.close(from.link); return; }
    to.held.append(bytes);
    io.pause_reading(from.link, true);
}
// doc:end copy

// doc:begin branch
// The backend is open: hand the pair to the loop when it has relay, otherwise copy through this library.
fn _pair<Io, S>(f: Forward&, io: Io&, has: S, client: Side&, backend: Side&) {
    const if same<S, goose_io::Supplied> {
        if io.relay(client.link, backend.link) == goose_io::RelayStatus.Started {
            f.relayed++;
        } else {
            io.close(client.link);
            io.close(backend.link);
        }
    } else {
        f.copied++;
        f._send_held(io, backend);
        if backend.held.len == 0 { io.pause_reading(client.link, false); }
    }
}
// doc:end branch

// The library's one entry point: true if the event was for a link of this forwarder, false if it is another library's.
fn forward_event<Io>(f: Forward&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => {
            if io.draining() {
                for s in f.sides { if s.in_use { io.close(s.link); } }
            }
            return false;
        },
        PassEnd => { return false; },
        Input i => { return false; },
        Expired x => { return false; },
        Woken w => { return false; },
        Opened o => {
            if goose_io::is_listener(o.listener) {
                guard goose_io::same(o.listener, f.listener) else { return false; }
                // an accepted link: hold its bytes back until the backend is open, then dial
                let c = f._new_side(o.link, true);
                io.pause_reading(o.link, true);
                let b = io.dial(f.backend[..], f.connect_ms);
                let j = f._new_side(b, false);
                f.sides[c].peer = j;
                f.sides[j].peer = c;
                return true;
            }
            // a dial of this forwarder opened: the library's own, if the link is in the table
            let j = f._side_of(o.link);
            guard j >= 0 else { return false; }
            let backend .= f.sides[j];
            backend.up = true;
            guard backend.peer >= 0 else { io.close(o.link); return true; }
            f._pair(io, goose_io::has_relay(io), f.sides[backend.peer], backend);
            return true;
        },
        Data d => {
            let i = f._side_of(d.link);
            guard i >= 0 else { return false; }
            f._copy(io, f.sides[i], d.bytes);
            return true;
        },
        Writable w => {
            let i = f._side_of(w.link);
            guard i >= 0 else { return false; }
            f._send_held(io, f.sides[i]);
            return true;
        },
        PeerEof e => {
            let i = f._side_of(e.link);
            guard i >= 0 else { return false; }
            // without half-close the end of one direction ends the connection
            let peer = f.sides[i].peer;
            if peer >= 0 { io.close(f.sides[peer].link); }
            io.close(e.link);
            return true;
        },
        Closed x => {
            let i = f._side_of(x.link);
            guard i >= 0 else { return false; }
            let peer = f.sides[i].peer;
            if peer >= 0 {
                f.sides[peer].peer = -1;
                io.close(f.sides[peer].link);
            }
            f.sides[i].in_use = false;
            f.free.push(i);
            f.refs.drop(x.link);
            return true;
        },
    }
}
