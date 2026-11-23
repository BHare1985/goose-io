// A fenced writer: it sends a payload to each client that connects, and promises that nothing is written after a
// fence time and that a cancelled stream leaves nothing queued. It shows the revoke capability
// (docs/capabilities/revoke.md).
//
// Needs: core and revoke (write_deadline, discard_unsent).
//
// `write_deadline` is the fence: from that time the loop writes no byte on the link, answers a send with `Closed` and
// ends the link, even if the library is not running at that moment. `discard_unsent` is the cancel: the bytes the loop
// accepted and has not handed to the transport are dropped, and it says how many. Neither can recall a byte already
// written. An example, not a library to depend on.
namespace fenced_writer;
import std;
import goose_io;

struct Conn { link: goose_io::Link = goose_io::Link { .. }, in_use: bool = false }
struct Ref { index: i64 = 0 }

root struct FencedWriter {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    payload:  u8[>..]                = [],      // what each client is sent
    lease_ms: i64                    = 0,       // how long after it opens a link may be written
    dropped:  i64                    = 0,       // bytes discarded by cancel
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
}

// Listens on `address`; each client is sent `payload`, and the loop writes nothing to it after `lease_ms`.
fn start<Io>(w: FencedWriter&, io: Io&, address: const u8[:], payload: const u8[:], lease_ms: i64) -> bool {
    w.payload.append(payload);
    w.lease_ms = lease_ms;
    let l, err = io.listen(address);
    w.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn dropped_bytes(w: FencedWriter&) -> i64 { w.dropped }

fn _conn_of(w: FencedWriter&, link: goose_io::Link) -> i64 {
    let r .= w.refs.find(link);
    guard r != null else { return -1; }
    guard r.index < w.conns.len && w.conns[r.index].in_use && goose_io::same(w.conns[r.index].link, link) else { return -1; }
    return r.index;
}

// doc:begin fence
// A client connected: fence the link, then send the payload.
fn _on_opened<Io>(w: FencedWriter&, io: Io&, link: goose_io::Link) {
    io.write_deadline(link, io.now_ms() + w.lease_ms);
    io.send(link, w.payload[..]);
}
// doc:end fence

// doc:begin cancel
// The stream is cancelled: what the loop has not written is dropped, and the links end.
fn cancel<Io>(w: FencedWriter&, io: Io&) {
    for c in w.conns {
        if !c.in_use { continue; }
        w.dropped += io.discard_unsent(c.link);
        io.close(c.link);
    }
}
// doc:end cancel

fn writer_event<Io>(w: FencedWriter&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, w.listener) else { return false; }
            w.conns.push(Conn { link: o.link, in_use: true });
            w.refs.put(o.link, Ref { index: w.conns.len - 1 });
            w._on_opened(io, o.link);
            return true;
        },
        Closed x => {
            let i = w._conn_of(x.link);
            guard i >= 0 else { return false; }
            w.conns[i].in_use = false;
            w.refs.drop(x.link);
            return true;
        },
        Data d => { return w._conn_of(d.link) >= 0; },
        PeerEof e => { return w._conn_of(e.link) >= 0; },
        Writable v => { return w._conn_of(v.link) >= 0; },
        _ => { return false; },
    }
}
