// The relay group with the revoke, peek and limits groups, on the in-memory loop (add-proxy-groups, 3.6): the rules that
// involve two groups at once and so belong to no entry of the suite. Two pairs of links, the accepted ends relayed to each
// other: client[0] - server[0] = server[1] - client[1]. GOOSE_IO_FAULT runs the tests against a fault of the loop.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

struct Ex { who: i64, limit: goose_io::Limit, at: i64 }

root struct Rig {
    l0:      goose_io::Listener = goose_io::Listener { .. },
    l1:      goose_io::Listener = goose_io::Listener { .. },
    client:  goose_io::Link[2]  = [goose_io::Link { .. }, goose_io::Link { .. }],
    server:  goose_io::Link[2]  = [goose_io::Link { .. }, goose_io::Link { .. }],
    open:    i64                = 0,
    step:    i64                = 0,
    t:       i64                = 0,
    n:       i64                = 0,
    expired: Ex[>..]            = [],
    keep:    bool               = false,    // keep client[1] open when its peer's stream ends (set in its Opened)
    seen:    u8[>..]            = [],       // what client[1] received
    peeked:  u8[>..]            = [],
}

fn use_fault(io: goose_io_memory::Loop&) {
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
}

fn start(io: goose_io_memory::Loop&, r: Rig&) {
    let a, ea = io.listen("127.0.0.1:7001");
    let b, eb = io.listen("127.0.0.1:7002");
    r.l0 = a;
    r.l1 = b;
    r.client[0] = io.dial("127.0.0.1:7001", 0);
    r.client[1] = io.dial("127.0.0.1:7002", 0);
}

fn index_of(r: Rig&, link: goose_io::Link) -> i64 {
    if link == r.server[0] { return 0; }
    if link == r.server[1] { return 1; }
    return -1;
}

// Notes the event; true once, when all four links are open.
fn track(io: goose_io_memory::Loop&, r: Rig&, log: kit::Log&, ev: goose_io::Event) -> bool {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if e.listener == r.l0 { r.server[0] = e.link; }
            else if e.listener == r.l1 { r.server[1] = e.link; }
            if r.keep && e.link == r.client[1] { io.set_keep_open_on_eof(e.link, true); }
            r.open++;
            return r.open == 4;
        },
        Data e => { if e.link == r.client[1] { r.seen.append(e.bytes); } },
        Expired e => { r.expired.push(Ex { who: index_of(r, e.link), limit: e.limit, at: io.now_ms() }); },
        _ => {},
    }
    return false;
}

fn count_of(r: Rig&, who: i64, limit: goose_io::Limit) -> i64 {
    var n = 0;
    for i in r.expired.len { if r.expired[i].who == who && r.expired[i].limit == limit { n++; } }
    return n;
}

fn first_at(r: Rig&, who: i64, limit: goose_io::Limit) -> i64 {
    for i in r.expired.len { if r.expired[i].who == who && r.expired[i].limit == limit { return r.expired[i].at; } }
    return -1;
}

fn pattern(n: i64) -> u8[>..] {
    var b: u8[>..] = [];
    for i in n { b.push((i % 251) as u8); }
    return b;
}

// Sends until the loop refuses.
fn fill(io: goose_io_memory::Loop&, link: goose_io::Link) -> i64 {
    var sent = 0;
    var more = true;
    while more {
        let chunk = pattern(io.max_send());
        if io.send(link, chunk[..]) == goose_io::SendStatus.Sent { sent += io.max_send(); } else { more = false; }
        if sent > (64 << 20) { more = false; }
    }
    return sent;
}

// A deadline on one link of a relayed pair binds the relay's writes in both directions: `into` is the side that does not
// read, and the bytes come from the other.
fn deadline_binds(toward_armed: bool) {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    start(io, r);
    io.serve() { io, ev =>
        if track(io, r, log, ev) {
            kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "fixture: relay");
            r.t = io.now_ms();
            io.write_deadline(r.server[0], r.t + 300);
            // the armed side's far end stays quiet or the other side's does: the relay writes in either direction
            if toward_armed { io.pause_reading(r.client[0], true); fill(io, r.client[1]); }
            else { io.pause_reading(r.client[1], true); fill(io, r.client[0]); }
            io.tick_by(r.t + 1000);
        }
        kit::stop_after(io, ev, r.t + 1000);
    };
    let which = if toward_armed { "toward" } else { "away from" };
    kit::check(kit::closed_once(log, r.server[0], goose_io::CloseReason.Local), "a deadline on a relayed link ends it with Local when the relay writes {which} it");
    kit::check(kit::closed_once(log, r.server[1], goose_io::CloseReason.Local), "and its partner with Local");
}

fn idle_counts_pair_once() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    start(io, r);
    io.serve() { io, ev =>
        if track(io, r, log, ev) {
            kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "fixture: relay");
            r.t = io.now_ms();
            io.set_limit(r.server[0], goose_io::Limit.Idle, 1000);
            io.tick_by(r.t + 500);
        }
        match ev {
            Tick t => {
                // a byte every 500 ms in one direction for 3 s, then nothing
                if t.now_ms < r.t + 3000 { io.send(r.client[1], "x"); io.tick_by(t.now_ms + 500); } else { io.tick_by(r.t + 6000); }
                if t.now_ms >= r.t + 6000 { io.stop(0); }
            },
            _ => {},
        }
    };
    kit::check(count_of(r, 0, goose_io::Limit.Idle) == 1 && first_at(r, 0, goose_io::Limit.Idle) >= r.t + 3000, "no Idle while bytes cross the relay, then one");
    kit::check(r.expired.len == 1, "and none for the other link, which was not armed");
}

fn stalled_on_relayed() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    start(io, r);
    io.serve() { io, ev =>
        if track(io, r, log, ev) {
            kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "fixture: relay");
            r.t = io.now_ms();
            io.pause_reading(r.client[1], true);
            fill(io, r.client[0]);
            io.set_limit(r.server[1], goose_io::Limit.Stalled, 600);
            io.tick_by(r.t + 2000);
        }
        kit::stop_after(io, ev, r.t + 2000);
    };
    kit::check(count_of(r, 1, goose_io::Limit.Stalled) == 1, "a relayed link whose peer never reads reports Stalled once");
    kit::check(first_at(r, 1, goose_io::Limit.Stalled) >= r.t + 600, "not before the period");
}

fn halfopen_on_relayed() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    r.keep = true;
    start(io, r);
    io.serve() { io, ev =>
        if track(io, r, log, ev) {
            kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "fixture: relay");
            r.t = io.now_ms();
            io.set_limit(r.server[0], goose_io::Limit.HalfOpen, 800);
            io.set_limit(r.server[1], goose_io::Limit.HalfOpen, 800);
            io.shutdown_write(r.client[0]);
            io.tick_by(r.t + 2000);
        }
        kit::stop_after(io, ev, r.t + 2000);
    };
    kit::check(count_of(r, 0, goose_io::Limit.HalfOpen) == 1, "a relayed pair left half-open reports HalfOpen on the link whose peer ended");
    kit::check(first_at(r, 0, goose_io::Limit.HalfOpen) >= r.t + 800, "not before the period");
}

// Peek shows the bytes of a link that waits for input, and the library may then relay it: nothing peeked is lost.
fn peek_then_relay() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    start(io, r);
    io.serve() { io, ev =>
        if track(io, r, log, ev) {
            r.t = io.now_ms();
            io.wait_input(r.server[0], 5);
            io.send(r.client[0], "hello");
        }
        match ev {
            Input i => {
                if i.link == r.server[0] && r.step == 0 {
                    r.step = 1;
                    r.peeked.append(io.peek(i.link));
                    kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "relay after peek");
                }
            },
            _ => {},
        }
        kit::stop_after(io, ev, r.t + 500);
    };
    kit::check(r.peeked[..] == "hello", "peek showed the bytes");
    kit::check(r.seen[..] == "hello", "the relay carried the bytes that were peeked, once");
}

fn main() {
    deadline_binds(true);
    deadline_binds(false);
    idle_counts_pair_once();
    stalled_on_relayed();
    halfopen_on_relayed();
    peek_then_relay();
    kit::finish();
}
