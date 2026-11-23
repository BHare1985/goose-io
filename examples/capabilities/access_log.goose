// An access log: it accepts connections, writes one line to a log for each (who connected), answers with the
// address it saw and leaves the link to the client, and stops accepting when the loop is stopping. It shows the inspection capability
// (docs/capabilities/inspection.md).
//
// Needs: core and inspection (peer_address, stop_listening).
//
// `peer_address` is asked in the handler of `Opened`, while the link is open: after `Closed` it is empty. `stop_listening`
// ends acceptance on one listener and leaves the links already accepted open, so a draining server stops taking new work
// and finishes what it has. An example, not a library to depend on.
namespace access_log;
import std;
import goose_io;

struct Conn { link: goose_io::Link = goose_io::Link { .. }, in_use: bool = false }
struct Ref { index: i64 = 0 }

root struct AccessLog {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    log:      u8[>..]                = [],     // one line per accepted connection: "<peer address>"
    stopped:  bool                   = false,  // stop_listening was called
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
}

fn start<Io>(a: AccessLog&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    a.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn log_text(a: AccessLog&) -> const u8[:] { a.log[..] }
fn is_stopped(a: AccessLog&) -> bool { a.stopped }

fn _conn_of(a: AccessLog&, link: goose_io::Link) -> i64 {
    let r .= a.refs.find(link);
    guard r != null else { return -1; }
    guard r.index < a.conns.len && a.conns[r.index].in_use && goose_io::same(a.conns[r.index].link, link) else { return -1; }
    return r.index;
}

// doc:begin opened
// A connection was accepted: write its line, and answer with the address the loop reports.
fn _on_opened<Io>(a: AccessLog&, io: Io&, link: goose_io::Link) {
    let peer = io.peer_address(link);
    a.log.append(peer.text[..]);
    a.log.append("\n");
    io.send(link, peer.text[..]);
}
// doc:end opened

// doc:begin draining
// A loop that is stopping takes no new connections; the ones it has finish.
fn _on_tick<Io>(a: AccessLog&, io: Io&) {
    if io.draining() && !a.stopped {
        io.stop_listening(a.listener);
        a.stopped = true;
    }
}
// doc:end draining

fn access_event<Io>(a: AccessLog&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => { a._on_tick(io); return false; },
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, a.listener) else { return false; }
            a.conns.push(Conn { link: o.link, in_use: true });
            a.refs.put(o.link, Ref { index: a.conns.len - 1 });
            a._on_opened(io, o.link);
            return true;
        },
        Closed x => {
            let i = a._conn_of(x.link);
            guard i >= 0 else { return false; }
            a.conns[i].in_use = false;
            a.refs.drop(x.link);
            return true;
        },
        Data d => { return a._conn_of(d.link) >= 0; },
        PeerEof e => { return a._conn_of(e.link) >= 0; },
        _ => { return false; },
    }
}
