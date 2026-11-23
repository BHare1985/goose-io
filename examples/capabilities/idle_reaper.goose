// A relay with limits: it carries each client to a backend with `relay` and closes a connection that has been idle for
// too long or has lived too long. It shows the limits capability (docs/capabilities/limits.md).
//
// Needs: core, relay and limits (set_limit, and the event Expired).
//
// Once a relay carries the bytes the library sees none of them, so it cannot tell by itself that a connection went
// quiet. It asks the loop: `set_limit(link, Limit.Idle, ms)` reports `Expired` when no byte moved on the link for `ms`,
// and `Limit.Age` when the link has been open that long, however busy. The loop does not close anything; the library
// does, and `close` on one link of a relayed pair ends both. An example, not a library to depend on.
namespace idle_reaper;
import std;
import goose_io;

struct Side { link: goose_io::Link = goose_io::Link { .. }, in_use: bool = false, peer: i64 = -1 }
struct Ref { index: i64 = 0 }

root struct IdleReaper {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    backend:  u8[..64]               = [],
    idle_ms:  i64                    = 0,
    age_ms:   i64                    = 0,
    idled:    i64                    = 0,        // connections closed for being idle
    aged:     i64                    = 0,        // connections closed for their age
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    sides:    Side[>..]              = [],
}

// Listens on `front`, relays each client to `backend`, and limits each connection to `idle_ms` without a byte and
// `age_ms` in all.
fn start<Io>(r: IdleReaper&, io: Io&, front: const u8[:], backend: const u8[:], idle_ms: i64, age_ms: i64) -> bool {
    r.backend.append(backend);
    r.idle_ms = idle_ms;
    r.age_ms = age_ms;
    let l, err = io.listen(front);
    r.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn idle_count(r: IdleReaper&) -> i64 { r.idled }
fn age_count(r: IdleReaper&) -> i64 { r.aged }

fn _side_of(r: IdleReaper&, link: goose_io::Link) -> i64 {
    let ref .= r.refs.find(link);
    guard ref != null else { return -1; }
    guard ref.index < r.sides.len && r.sides[ref.index].in_use && goose_io::same(r.sides[ref.index].link, link) else { return -1; }
    return ref.index;
}

fn _add(r: IdleReaper&, link: goose_io::Link) -> i64 {
    r.sides.push(Side { link: link, in_use: true, peer: -1 });
    r.refs.put(link, Ref { index: r.sides.len - 1 });
    return r.sides.len - 1;
}

// doc:begin arm
// The pair is relayed: from now on the loop watches it. Either link's limit closes the connection.
fn _arm<Io>(r: IdleReaper&, io: Io&, client: goose_io::Link, backend: goose_io::Link) {
    io.set_limit(client, goose_io::Limit.Idle, r.idle_ms);
    io.set_limit(client, goose_io::Limit.Age, r.age_ms);
}
// doc:end arm

// doc:begin expired
// A limit ran out: say which, and close. Closing one link of a relayed pair ends both.
fn _on_expired<Io>(r: IdleReaper&, io: Io&, link: goose_io::Link, limit: goose_io::Limit) {
    match limit {
        Idle => { r.idled++; },
        Age => { r.aged++; },
        _ => {},
    }
    io.close(link);
}
// doc:end expired

fn reaper_event<Io>(r: IdleReaper&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            if goose_io::is_listener(o.listener) {
                guard goose_io::same(o.listener, r.listener) else { return false; }
                let c = r._add(o.link);
                io.pause_reading(o.link, true);
                let b = io.dial(r.backend[..], 5000);
                let j = r._add(b);
                r.sides[c].peer = j;
                r.sides[j].peer = c;
                return true;
            }
            let j = r._side_of(o.link);
            guard j >= 0 else { return false; }
            let c = r.sides[j].peer;
            guard c >= 0 else { io.close(o.link); return true; }
            if io.relay(r.sides[c].link, o.link) == goose_io::RelayStatus.Started {
                r._arm(io, r.sides[c].link, o.link);
            } else {
                io.close(r.sides[c].link);
                io.close(o.link);
            }
            return true;
        },
        Expired x => {
            guard r._side_of(x.link) >= 0 else { return false; }
            r._on_expired(io, x.link, x.limit);
            return true;
        },
        Closed x => {
            let i = r._side_of(x.link);
            guard i >= 0 else { return false; }
            let peer = r.sides[i].peer;
            if peer >= 0 { r.sides[peer].peer = -1; io.close(r.sides[peer].link); }
            r.sides[i].in_use = false;
            r.refs.drop(x.link);
            return true;
        },
        Data d => { return r._side_of(d.link) >= 0; },
        PeerEof e => { return r._side_of(e.link) >= 0; },
        _ => { return false; },
    }
}
