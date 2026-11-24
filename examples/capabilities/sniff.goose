// A protocol sniffer: it looks at the first bytes of each connection, says which protocol they look like, and then lets
// the connection's bytes through to the library untouched. It shows the peek capability (docs/capabilities/peek.md).
//
// Needs: core and peek (wait_input, peek, and the event Input).
//
// `wait_input(link, 4)` holds the link's bytes back until four have arrived. `Input` says how many there are and carries
// none: `peek` shows them without taking them. The library answers with the protocol it recognised, and
// `wait_input(link, 0)` then delivers the held bytes, unchanged and in order, as `Data`. A library that decided to hand
// the link to someone else would call `relay` here instead and never see them. An example, not a library to depend on.
namespace sniff;
import std;
import goose_io;

let LOOK = 4;           // bytes needed to tell the protocols apart

struct Mine { yes: bool = true }

root struct Sniff {
    listener: goose_io::Listener      = goose_io::Listener { .. },
    mine:     goose_io::LinkMap<Mine> = goose_io::LinkMap<Mine> {},
    seen:     u8[>..]                 = [],     // the bytes delivered as Data after the sniff
    http:     i64                     = 0,
    other:    i64                     = 0,
}

fn start<Io>(s: Sniff&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    s.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn http_count(s: Sniff&) -> i64 { s.http }
fn other_count(s: Sniff&) -> i64 { s.other }
fn data_after(s: Sniff&) -> const u8[:] { s.seen[..] }

// doc:begin classify
// The first bytes are here. Look at them, answer, and let them through as Data.
fn _on_input<Io>(s: Sniff&, io: Io&, link: goose_io::Link) {
    let first = io.peek(link);
    if first.len >= LOOK && first[0..LOOK] == "GET " {
        s.http++;
        io.send(link, "http\n");
    } else {
        s.other++;
        io.send(link, "unknown\n");
    }
    io.wait_input(link, 0);
}
// doc:end classify

fn sniff_event<Io>(s: Sniff&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, s.listener) else { return false; }
            s.mine.put(o.link, Mine { .. });
            io.wait_input(o.link, LOOK);
            return true;
        },
        Input i => {
            guard s.mine.find(i.link) != null else { return false; }
            s._on_input(io, i.link);
            return true;
        },
        Data d => {
            guard s.mine.find(d.link) != null else { return false; }
            s.seen.append(d.bytes);
            return true;
        },
        Closed x => {
            guard s.mine.find(x.link) != null else { return false; }
            s.mine.drop(x.link);
            return true;
        },
        PeerEof e => { return s.mine.find(e.link) != null; },
        _ => { return false; },
    }
}
