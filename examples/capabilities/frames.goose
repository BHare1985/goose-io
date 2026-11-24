// A frame streamer: it sends one body to each client that connects, as length-prefixed frames sized to what the link
// will take now. It shows the sizing capability (docs/capabilities/sizing.md).
//
// Needs: core and sizing (send_room, send2).
//
// A frame is a four-byte big-endian length and that many bytes. `send2` sends the header and the payload as one send,
// so the payload is never copied next to its header; `send_room` says how much a send would take, so a frame is cut
// to fit and not refused. When nothing fits, the send is made anyway: its `Full` is how the library asks the loop for
// one `Writable`, and the next frame goes out then. An example, not a library to depend on.
namespace frames;
import std;
import goose_io;

let FRAME_MAX = 1024;           // the most payload in one frame
let HEADER = 4;

struct Conn {
    link:   goose_io::Link = goose_io::Link { .. },
    in_use: bool           = false,
    sent:   i64            = 0,         // bytes of the body already framed and sent
}

struct Ref { index: i64 = 0 }

root struct Frames {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    body:     u8[>..]                = [],     // what each client is sent
    frames:   i64                    = 0,      // frames sent
    refused:  i64                    = 0,      // sends refused with Full
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
}

// Listens on `address`; every client that connects is sent `body`, framed, and then closed.
fn start<Io>(f: Frames&, io: Io&, address: const u8[:], body: const u8[:]) -> bool {
    f.body.append(body);
    let l, err = io.listen(address);
    f.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn frame_count(f: Frames&) -> i64 { f.frames }
fn refused_count(f: Frames&) -> i64 { f.refused }

fn _conn_of(f: Frames&, link: goose_io::Link) -> i64 {
    let r .= f.refs.find(link);
    guard r != null else { return -1; }
    guard r.index < f.conns.len && f.conns[r.index].in_use && goose_io::same(f.conns[r.index].link, link) else { return -1; }
    return r.index;
}

// doc:begin pump
// Sends frames while the link takes them. Each is cut to the room the link has; with no room it is sent at full size and
// refused, which arms Writable.
fn _pump<Io>(f: Frames&, io: Io&, c: Conn&) {
    while c.sent < f.body.len {
        let room = io.send_room(c.link);
        var n = min(f.body.len - c.sent, FRAME_MAX);
        if room > HEADER { n = min(n, room - HEADER); }
        let size = n;
        let header: u8[4] = [(size >> 24) as u8, (size >> 16) as u8, (size >> 8) as u8, size as u8];
        let status = io.send2(c.link, header[..], f.body[c.sent..c.sent + n]);
        if status == goose_io::SendStatus.Full { f.refused++; return; }
        if status != goose_io::SendStatus.Sent { io.close(c.link); return; }
        c.sent += n;
        f.frames++;
    }
    io.close(c.link);       // the whole body is framed; close sends what is held, then ends the link
}
// doc:end pump

// The library's one entry point: true if the event was for a link of this library.
fn frames_event<Io>(f: Frames&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, f.listener) else { return false; }
            f.conns.push(Conn { link: o.link, in_use: true, .. });
            f.refs.put(o.link, Ref { index: f.conns.len - 1 });
            f._pump(io, f.conns[f.conns.len - 1]);
            return true;
        },
        Writable w => {
            let i = f._conn_of(w.link);
            guard i >= 0 else { return false; }
            f._pump(io, f.conns[i]);
            return true;
        },
        Closed x => {
            let i = f._conn_of(x.link);
            guard i >= 0 else { return false; }
            f.conns[i].in_use = false;
            f.refs.drop(x.link);
            return true;
        },
        Data d => { return f._conn_of(d.link) >= 0; },
        PeerEof e => { return f._conn_of(e.link) >= 0; },
        _ => { return false; },
    }
}
