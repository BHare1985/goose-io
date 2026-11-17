// Dispatch micro-benchmark: what the contract's event path costs per event, apart from any real I/O.
//
// Events are built up front, so no event loop is involved: this measures only what the application and the libraries do
// with an `Event` once they have it. Each strategy delivers the same events (tags spread evenly over the
// libraries) and the time is divided by the number of events.
//
//   floor      one handler, no tag, no connection lookup: the least any handler can do with a Data event
//   one lib    one library: variant switch, tag check, connection lookup, count the bytes
//   chain      N libraries offered each event in turn; each checks its own tag (what gateway::step does)
//   routed     the application switches on goose_io::tag_of once and calls only the owner, which does not check
//   routed+chk as routed, and the library still checks (belt and braces)
//
// Run:  goose build bench/dispatch_bench.goose -o /tmp/dispatch_bench && /tmp/dispatch_bench
// (`goose run` compiles at -O1; build uses -O2, which is the figure that matters.)
import std;
import os;
import goose_io from "..";

let EVENTS = 4096;      // events per round; a power of two so the index wraps with a mask
let ROUNDS = 20000;
let MAX_LIBS = 8;

struct Conn { link: goose_io::Link = goose_io::Link { .. }, bytes: i64 = 0, events: i64 = 0 }

struct Lib {
    tag:   u16        = 0,
    conns: Conn[..16] = [],
    total: i64        = 0,
}

fn _conn_of(l: Lib&, user: u32, link: goose_io::Link) -> i64 {
    let i = user as i64 - 1;
    if i >= 0 && i < l.conns.len && goose_io::same(l.conns[i].link, link) { return i; }
    return -1;
}

// What a library's entry point does today (see examples/lineserver/server.goose `server_event`), cut to Data and
// to a byte count. The tag check is the line this benchmark is about.
fn lib_event(l: Lib&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => { return false; },
        PassEnd => { return false; },
        Data e => {
            if e.tag != l.tag { return false; }
            let i = l._conn_of(e.user, e.link);
            if i >= 0 { l.conns[i].bytes += e.bytes.len; l.total += e.bytes.len; }
            return true;
        },
        _ => {
            if goose_io::tag_of(ev) != l.tag { return false; }
            return true;
        },
    }
}

// The same, for a library the application has already routed to: no tag check.
fn lib_owned(l: Lib&, ev: goose_io::Event) {
    match ev {
        Data e => {
            let i = l._conn_of(e.user, e.link);
            if i >= 0 { l.conns[i].bytes += e.bytes.len; l.total += e.bytes.len; }
        },
        _ => {},
    }
}

fn floor_event(ev: goose_io::Event, sum: i64&) {
    match ev {
        Data e => { sum += e.bytes.len; },
        _ => {},
    }
}

fn chain(libs: Lib[..8]&, n: i64, ev: goose_io::Event) {
    for i in n { if libs[i].lib_event(ev) { break; } }
}

fn routed(libs: Lib[..8]&, ev: goose_io::Event) {
    if goose_io::is_link_event(ev) {
        let t = goose_io::tag_of(ev) as i64;
        if t >= 1 && t <= MAX_LIBS { libs[t - 1].lib_owned(ev); }
    }
}

fn routed_checked(libs: Lib[..8]&, ev: goose_io::Event) {
    if goose_io::is_link_event(ev) {
        let t = goose_io::tag_of(ev) as i64;
        if t >= 1 && t <= MAX_LIBS { libs[t - 1].lib_event(ev); }
    }
}

fn make_libs(libs: Lib[..8]&, n: i64) {
    libs.clear();
    for k in MAX_LIBS {
        var l = Lib { tag: (k + 1) as u16, .. };
        // one connection per library, link slot k, user value 1
        l.conns.push(Conn { link: goose_io::Link { slot: k as u32, gen: 1 }, .. });
        libs.push(l);
    }
}

fn total_of(libs: Lib[..8]&) -> i64 {
    var t = 0;
    for &l in libs { t += l.total; }
    return t;
}

fn report(name: const u8[:], n: i64, t0: i64, t1: i64, check: i64) {
    let events = EVENTS * ROUNDS;
    let ns = (t1 - t0) / events as f64;
    print(name, "  libs=", n, "  ", ns, " ns/event   (checksum ", check, ")");
}

fn main() {
    let payload: u8[64] = [0x61; 64];
    var evs: goose_io::Event[>..] = [];
    var libs: Lib[..8] = [];
    var sink = 0;

    for n_libs in [1, 4, 8] {
        // tags spread evenly over the n_libs libraries; the owner of event i is library (i % n_libs)
        evs.clear();
        for i in EVENTS {
            let k = i % n_libs;
            evs.push(goose_io::Event.Data { link: goose_io::Link { slot: k as u32, gen: 1 }, tag: (k + 1) as u16, user: 1, bytes: payload[..] });
        }

        var sum = 0;
        var t0 = clock_ns();
        for r in ROUNDS { for &ev in evs { floor_event(ev, sum); } }
        report("floor     ", n_libs, t0, clock_ns(), sum);

        make_libs(libs, n_libs);
        t0 = clock_ns();
        for r in ROUNDS { for &ev in evs { libs[0].lib_event(ev); } }
        report("one lib   ", n_libs, t0, clock_ns(), total_of(libs));

        make_libs(libs, n_libs);
        t0 = clock_ns();
        for r in ROUNDS { for &ev in evs { chain(libs, n_libs, ev); } }
        report("chain     ", n_libs, t0, clock_ns(), total_of(libs));

        make_libs(libs, n_libs);
        t0 = clock_ns();
        for r in ROUNDS { for &ev in evs { routed(libs, ev); } }
        report("routed    ", n_libs, t0, clock_ns(), total_of(libs));

        make_libs(libs, n_libs);
        t0 = clock_ns();
        for r in ROUNDS { for &ev in evs { routed_checked(libs, ev); } }
        report("routed+chk", n_libs, t0, clock_ns(), total_of(libs));
        print("");
    }
}
