// In-memory provider: the clock, ticks, tick_by, PassEnd, stop and draining, the time limit.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn is_link_kind(kind: u8) -> bool { kind >= kit::OPENED && kind <= kit::CLOSED }

// --- regular ticks -------------------------------------------------------------------------------

struct Ticks { n: i64 = 0, last: i64 = -1, widest: i64 = 0, in_order: bool = true, matches_clock: bool = true }

fn ticks_event(k: Ticks&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Tick t => {
            k.n++;
            if t.now_ms < k.last { k.in_order = false; }
            if t.now_ms != io.now_ms() { k.matches_clock = false; }
            let gap = t.now_ms - (if k.last < 0 { 0 } else { k.last });
            if gap > k.widest { k.widest = gap; }
            k.last = t.now_ms;
        },
        _ => {},
    }
    kit::stop_after(io, ev, 1000);
}

fn regular_ticks() {
    var io = goose_io_memory::Loop { .. };
    var k = Ticks { .. };
    kit::check(io.now_ms() == 0, "the clock starts at 0");
    io.serve() { io, ev => ticks_event(k, io, ev); };
    kit::check(k.n >= 10, "one second with no link activity delivers at least ten Ticks");
    kit::check(k.in_order, "Tick times never decrease");
    kit::check(k.widest <= 100, "no gap between Ticks is longer than 100 ms");
    kit::check(k.matches_clock, "a Tick carries now_ms");
    kit::check(io.now_ms() == 1000, "the clock moved exactly as far as the events needed");
    kit::check(io.passes() <= 11, "an idle loop makes one pass per Tick");
}

// --- tick_by -------------------------------------------------------------------------------------

struct Early { asked_at: i64 = -1, got_at: i64 = -1, past_asked: i64 = -1, past_got: i64 = -1 }

fn early_event(e: Early&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Tick t => {
            if e.asked_at < 0 {
                e.asked_at = t.now_ms;
                io.tick_by(t.now_ms + 20);
                io.tick_by(t.now_ms + 70);          // a later request does not displace an earlier one
            } else if e.got_at < 0 {
                e.got_at = t.now_ms;
            } else if e.past_asked < 0 && t.now_ms >= 400 {
                e.past_asked = t.now_ms;
                io.tick_by(t.now_ms - 50);          // a time already passed: a Tick comes promptly
            } else if e.past_asked >= 0 && e.past_got < 0 {
                e.past_got = t.now_ms;
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 800);
}

fn short_deadline() {
    var io = goose_io_memory::Loop { .. };
    var e = Early { .. };
    io.serve() { io, ev => early_event(e, io, ev); };
    kit::check(e.got_at >= e.asked_at + 20, "the Tick asked for comes at or after the requested time");
    kit::check(e.got_at < e.asked_at + 100, "and before the next regular tick would have");
    kit::check(e.got_at == e.asked_at + 20, "on this provider's clock, exactly then");
    kit::check(e.past_got >= 0 && e.past_got - e.past_asked <= 1, "tick_by with a time already passed gives a Tick promptly");
}

// Two libraries on one loop, each with its own repeating deadline, each asking again on every Tick.
struct Timer { period: i64 = 0, due: i64 = 0, fired: i64 = 0, worst_late: i64 = 0 }

fn timer_tick(tm: Timer&, io: goose_io_memory::Loop&, now: i64) {
    if now >= tm.due {
        tm.fired++;
        if now - tm.due > tm.worst_late { tm.worst_late = now - tm.due; }
        tm.due = now + tm.period;
    }
    io.tick_by(tm.due);
}

fn two_event(a: Timer&, b: Timer&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Tick t => { timer_tick(a, io, t.now_ms); timer_tick(b, io, t.now_ms); },
        _ => {},
    }
    kit::stop_after(io, ev, 1000);
}

fn two_deadlines() {
    var io = goose_io_memory::Loop { .. };
    var a = Timer { period: 20, due: 20, .. };
    var b = Timer { period: 50, due: 50, .. };
    io.tick_by(20);
    io.serve() { io, ev => two_event(a, b, io, ev); };
    kit::check(a.fired == 50, "the 20 ms library saw every one of its deadlines in one second");
    kit::check(b.fired == 20, "and so did the 50 ms library");
    kit::check(a.worst_late == 0 && b.worst_late == 0, "each at its own time, sharing one tick_by");
}

// --- PassEnd -------------------------------------------------------------------------------------

struct Batch {
    servers: goose_io::Link[..16] = [],
    clients: goose_io::Link[..16] = [],
    got:     goose_io::Link[..16] = [],     // server links that received a request in the current pass
    asked:   bool                 = false,
}

fn batch_event(b: Batch&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { if e.tag == 1 { b.servers.push(e.link); } },
        Data d => { if d.tag == 1 { b.got.push(d.link); } },
        PassEnd => {
            // the batch: one reply to every request of this pass
            for l in b.got { kit::check(io.send(l, "reply") == goose_io::SendStatus.Sent, "an operation in PassEnd behaves as anywhere else"); }
            b.got.clear();
        },
        Tick t => {
            if !b.asked {
                b.asked = true;
                for c in b.clients { io.send(c, "request"); }
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 500);
}

fn pass_end() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    log.ticks = true;
    var b = Batch { .. };
    let l, err = io.listen("127.0.0.1:8200", 1);
    for i in 10 { b.clients.push(io.dial("127.0.0.1:8200", 2, 0)); }
    io.serve() { io, ev => batch_event(b, log, io, ev); };      // nothing asks for PassEnd: it is always delivered

    // the shape of the whole log
    var after_link_ok = true;
    var before_pass_end_ok = true;
    for e, i in log.entries {
        if is_link_kind(e.kind) {
            let next = if i + 1 < log.entries.len { log.entries[i + 1].kind } else { 0 };
            if !is_link_kind(next) && next != kit::PASS_END { after_link_ok = false; }
        }
        if e.kind == kit::PASS_END {
            if i == 0 || !is_link_kind(log.entries[i - 1].kind) { before_pass_end_ok = false; }
        }
    }
    kit::check(after_link_ok, "the last link event of a pass is followed by PassEnd, before any Tick");
    kit::check(before_pass_end_ok, "a PassEnd only ever follows a link event: none for a pass with only a Tick, never two in a row");

    // ten requests in one pass: ten Data, then exactly one PassEnd
    let first = kit::nth(log, kit::DATA, 0);
    var ten = first >= 0 && first + 10 < log.entries.len;
    if ten {
        for k in 10 { if log.entries[first + k].kind != kit::DATA || log.entries[first + k].tag != 1 { ten = false; } }
        if log.entries[first + 10].kind != kit::PASS_END { ten = false; }
    }
    kit::check(ten, "ten requests arriving in one pass give ten Data events and then one PassEnd");
    var replies = 0;
    for c in b.clients { if kit::data_of(log, c) == "reply" { replies++; } }
    kit::check(replies == 10, "the replies sent while handling PassEnd arrived");
    kit::check(kit::count(log, kit::PASS_END) == 4, "four passes had link events (opens, requests, replies, the closes at stop) and each got one PassEnd");
    kit::check(log.entries[log.entries.len - 1].kind == kit::PASS_END, "the pass that delivers the last Closed still ends with PassEnd before serve returns");
}

// PassEnd is the last event of its pass: no link event and no Tick of that pass comes after it.
struct Last { pass_of_pass_end: i64 = -1, after: i64 = 0, together: bool = false, link_pass: i64 = -1, tick_pass: i64 = -1, ends: i64 = 0 }

fn last_event(s: Last&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if io.passes() == s.pass_of_pass_end { s.after++; }
    match ev {
        PassEnd => { s.pass_of_pass_end = io.passes(); s.ends++; },
        Tick t => { s.tick_pass = io.passes(); if s.tick_pass == s.link_pass { s.together = true; } },
        _ => { s.link_pass = io.passes(); if s.tick_pass == s.link_pass { s.together = true; } },
    }
    kit::stop_after(io, ev, 300);
}

fn pass_end_is_last() {
    var io = goose_io_memory::Loop { .. };
    var s = Last { .. };
    let l, err = io.listen("127.0.0.1:8207", 1);
    // peers whose bytes arrive in the very pass that also has a Tick
    for i in 3 {
        let p = io.add_peer();
        io.peer_connect(p, "127.0.0.1:8207", 0);
        io.peer_send(p, 100, "at the tick");
        io.peer_send(p, 100, "and the next");
    }
    io.serve() { io, ev => last_event(s, io, ev); };
    kit::check(s.ends >= 3, "fixture: several passes had link events");
    kit::check(s.together, "fixture: one pass had both a Tick and link events");
    kit::check(s.after == 0, "nothing of a pass, link event or Tick, is delivered after its PassEnd");
}

// --- stop and draining ---------------------------------------------------------------------------

fn idle_stop_event(io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Tick t => {
            kit::check(!io.draining(), "draining is false before stop");
            io.stop(5000);
            kit::check(io.draining(), "draining is true as soon as stop is called");
        },
        _ => {},
    }
}

fn stop_with_nothing_open() {
    var io = goose_io_memory::Loop { .. };
    let l, err = io.listen("127.0.0.1:8201", 1);
    io.serve() { io, ev => idle_stop_event(io, ev); };
    kit::check(io.now_ms() == 100, "with no link open, serve returns without waiting for the grace period");
    let l2, err2 = io.listen("127.0.0.1:8202", 1);
    kit::check(!goose_io::is_listener(l2) && goose_io::failed(err2), "listen on a loop that is stopping fails");
}

struct Linger { p: kit::Pair = kit::Pair { .. }, stopped_at: i64 = -1, late: goose_io::Link = goose_io::Link { .. }, out: goose_io::Link = goose_io::Link { .. }, saw_draining: bool = false }

fn linger_event(s: Linger&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::track(s.p, log, io, ev);
    match ev {
        Tick t => {
            if s.stopped_at < 0 {
                s.stopped_at = t.now_ms;
                io.stop(2000);
                s.late = io.dial("127.0.0.1:8203", 3, 0);       // the listener stopped at once
                let l, err = io.listen("127.0.0.1:8206", 1);
                kit::check(!goose_io::is_listener(l) && goose_io::failed(err), "listen fails once the loop is stopping");
                s.out = io.dial("10.0.0.20:80", 3, 0);          // dialling out is still allowed
            } else if io.draining() {
                s.saw_draining = true;
            }
        },
        _ => {},
    }
}

fn stop_with_a_link_open() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Linger { .. };
    kit::connect(io, s.p, "127.0.0.1:8203");
    let upstream = io.add_peer();
    io.peer_accept(upstream, "10.0.0.20:80");
    io.serve() { io, ev => linger_event(s, log, io, ev); };
    kit::check(kit::first_for(log, kit::OPENED, s.out) >= 0, "a library can still dial while the loop is stopping, to finish work in hand");
    kit::check(kit::closed_once(log, s.out, goose_io::CloseReason.Shutdown), "and that link is closed with Shutdown at the end of the grace period like any other");
    let oi = kit::first_for(log, kit::CLOSED, s.out);
    kit::check(oi >= 0 && log.entries[oi].at_ms == s.stopped_at + 2000, "a link dialled while stopping does not extend the grace period");
    kit::check(s.saw_draining, "draining is true for later handlers");
    kit::check(kit::failed_with(log, s.late, goose_io::ConnectFailure.Refused), "no connection is accepted after stop");
    kit::check(kit::closed_once(log, s.p.client, goose_io::CloseReason.Shutdown), "a link still open at the end of the grace period is closed with Shutdown");
    kit::check(kit::closed_once(log, s.p.server, goose_io::CloseReason.Shutdown), "every one of them");
    let i = kit::first_for(log, kit::CLOSED, s.p.client);
    kit::check(i >= 0 && log.entries[i].at_ms == s.stopped_at + 2000, "exactly when the grace period ends");
    kit::check(io.now_ms() == s.stopped_at + 2000, "and serve returns then, after delivering those Closed events");
}

struct Polite { p: kit::Pair = kit::Pair { .. }, stopped: bool = false }

fn polite_event(s: Polite&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::track(s.p, log, io, ev);
    match ev {
        Tick t => {
            if !s.stopped { s.stopped = true; io.stop(5000); }
            else if io.draining() { io.close(s.p.client); }     // a library that finishes when asked
        },
        _ => {},
    }
}

fn stop_and_libraries_finish() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Polite { .. };
    kit::connect(io, s.p, "127.0.0.1:8204");
    io.serve() { io, ev => polite_event(s, log, io, ev); };
    kit::check(kit::closed_once(log, s.p.client, goose_io::CloseReason.Local), "the library closed its own link");
    kit::check(kit::closed_once(log, s.p.server, goose_io::CloseReason.PeerClosed), "the other end followed");
    kit::check(io.now_ms() < 1000, "serve returns as soon as the last Closed is delivered, long before the grace period ends");
}

struct Twice { p: kit::Pair = kit::Pair { .. }, stops: i64 = 0 }

fn twice_event(s: Twice&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::track(s.p, log, io, ev);
    match ev {
        Tick t => {
            if s.stops == 0 { s.stops = 1; io.stop(300); }
            else if s.stops == 1 { s.stops = 2; io.stop(5000); }    // a later, longer grace does not extend the first
        },
        _ => {},
    }
}

fn stop_twice() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Twice { .. };
    kit::connect(io, s.p, "127.0.0.1:8205");
    io.serve() { io, ev => twice_event(s, log, io, ev); };
    kit::check(io.now_ms() == 400, "the earliest end of grace stands");
    kit::check(kit::closed_once(log, s.p.client, goose_io::CloseReason.Shutdown), "and the link is closed with Shutdown then");
}

// --- the time limit ------------------------------------------------------------------------------

fn time_limit() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.time_limit_ms = 3000;
    io.cfg.exit_on_time_limit = false;
    var n = 0;
    kit::check(!io.hit_time_limit(), "fixture: the limit is not hit before serve");
    io.serve() { io, ev => { n++; } };          // a handler that never stops the loop
    kit::check(io.hit_time_limit(), "a loop that nothing stops ends at the time limit");
    kit::check(io.now_ms() > 3000 && io.now_ms() <= 3100, "at the limit, not long after");
}

// --- a configuration that would stop the clock --------------------------------------------------

// Counts events that arrive while the clock stands still, and gives up on its own account instead of
// hanging the test run.
struct Stuck { ticks: i64 = 0, at: i64 = -1, same: i64 = 0, gave_up: bool = false }

fn stuck_event(k: Stuck&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if io.now_ms() == k.at { k.same++; } else { k.at = io.now_ms(); k.same = 0; }
    if k.same > 10000 { k.gave_up = true; io.stop(0); return; }
    match ev {
        Tick t => { k.ticks++; },
        _ => {},
    }
    kit::stop_after(io, ev, 50);
}

fn tick_period(period: i64, what: const u8[:]) {
    var io = goose_io_memory::Loop { .. };
    io.cfg.tick_ms = period;
    var k = Stuck { .. };
    io.serve() { io, ev => stuck_event(k, io, ev); };
    kit::check(!k.gave_up, what);
    kit::check(io.now_ms() >= 50, "the clock reached the time the handler stopped at");
    kit::check(k.ticks <= io.now_ms() + 1, "at most one Tick for each millisecond of the clock");
}

fn tick_period_below_one() {
    tick_period(0, "a tick_ms of 0 does not stop the clock");
    tick_period(-5, "a negative tick_ms does not stop the clock");
}

fn negative_tick_runs_to_the_limit() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.tick_ms = -5;
    io.cfg.time_limit_ms = 1000;
    io.cfg.exit_on_time_limit = false;
    var n = 0;
    io.serve() { io, ev => { n++; if n > 1000000 { io.stop(0); } } };
    kit::check(n <= 1000000, "a negative tick_ms with nothing to stop the loop still reaches the time limit");
    kit::check(io.hit_time_limit(), "and reports it");
}

struct Echo { p: kit::Pair = kit::Pair { .. }, rounds: i64 = 0 }

fn echo_event(e: Echo&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(e.p, log, io, ev) { io.send(e.p.client, "a"); }
    match ev {
        Data d => { e.rounds++; io.send(d.link, d.bytes); },
        _ => {},
    }
    kit::stop_after(io, ev, 50);
}

fn pass_rate_of_zero() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.passes_per_ms = 0;
    var log = kit::Log { .. };
    var e = Echo { .. };
    kit::connect(io, e.p, "127.0.0.1:8300");
    io.serve() { io, ev => echo_event(e, log, io, ev); };
    kit::check(e.rounds > 10, "fixture: the two links exchanged bytes while the clock moved");
    kit::check(io.now_ms() >= 50 && !io.hit_time_limit(), "a passes_per_ms of 0 ends normally");
}

fn main() {
    regular_ticks();
    short_deadline();
    two_deadlines();
    pass_end();
    pass_end_is_last();
    stop_with_nothing_open();
    stop_with_a_link_open();
    stop_and_libraries_finish();
    stop_twice();
    time_limit();
    tick_period_below_one();
    negative_tick_runs_to_the_limit();
    pass_rate_of_zero();
    kit::finish();
}
