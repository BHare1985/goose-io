// goose-io conformance suite, group 4.7: time, ticks, end-of-pass, and the host side (run and stop).
// Requirements: Time and ticks; End-of-pass notification; The host runs and stops the loop; Draining is the same
// on every provider.
//
// The contract does not let a check see where one pass ends and the next begins, so the PassEnd checks assert
// what the rules make visible in the event sequence: a PassEnd comes only after link events, never twice with
// no link event between, and a link event is followed by a PassEnd before the next Tick (a Tick opens the next pass).
//
// Parts: 0 holds everything but `stop`, ending with "stop with nothing open"; parts 1 to 5 are one `stop`
// scenario each (a link that stays open, libraries that finish, listening while draining, dialling while
// draining, stop called twice).
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn time_info(id: i64) -> Info {
    if id == 500 { return Info { name: "ticks_are_regular", req: "Time and ticks", part: 0 }; }
    if id == 501 { return Info { name: "tick_by_is_prompt", req: "Time and ticks", part: 0 }; }
    if id == 502 { return Info { name: "tick_by_two_deadlines", req: "Time and ticks", part: 0 }; }
    if id == 503 { return Info { name: "pass_end_follows_link_events", req: "End-of-pass notification", part: 0 }; }
    if id == 504 { return Info { name: "pass_end_not_on_idle_pass", req: "End-of-pass notification", part: 0 }; }
    if id == 505 { return Info { name: "stop_with_nothing_open", req: "The host runs and stops the loop", part: 0 }; }
    if id == 510 { return Info { name: "stop_link_stays_open", req: "The host runs and stops the loop", part: 1 }; }
    if id == 520 { return Info { name: "stop_libraries_finish", req: "The host runs and stops the loop", part: 2 }; }
    if id == 530 { return Info { name: "listen_while_draining", req: "Draining is the same on every provider", part: 3 }; }
    if id == 540 { return Info { name: "dial_while_draining", req: "Draining is the same on every provider", part: 4 }; }
    if id == 550 { return Info { name: "stop_called_twice", req: "Draining is the same on every provider", part: 5 }; }
    return Info { .. };
}

fn tick_time(ev: goose_io::Event) -> i64 {
    match ev {
        Tick t => { return t.now_ms; },
        _ => { return -1; },
    }
}

// --- 500: regular ticks ------------------------------------------------------------------------------------------

fn c_ticks_are_regular<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.t = io.now_ms();
        k.m = -1;
        k.within(io, 5000);
        k.step = 1;
    } else {
        let t = tick_time(ev);
        if t >= 0 {
            k.n++;
            k.expect(t >= k.m, "Tick times went backwards");
            k.expect(t == io.now_ms(), "a Tick did not carry the loop's clock");
            if k.m >= 0 { k.expect(t - k.m <= 100, "two Ticks were more than 100 ms apart"); }
            k.m = t;
        }
        if io.now_ms() >= k.t + 1000 {
            k.expect(k.n >= 10, "one second of the loop's clock gave fewer than ten Ticks");
            k.finish();
        }
    }
}

// --- 501: a deadline shorter than the tick period ---------------------------------------------------------------------

fn c_tick_by_is_prompt<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.within(io, 5000);
        k.step = 1;
    } else if k.step == 1 && tick_time(ev) >= 0 {
        // asked for in the handler of a Tick: 20 ms after it
        k.t = tick_time(ev);
        io.tick_by(k.t + 20);
        k.step = 2;
    } else if k.step == 2 && tick_time(ev) >= 0 {
        let t = tick_time(ev);
        k.expect(t >= k.t + 20, "the Tick after tick_by came before the time asked for");
        k.expect(t < k.t + 100, "tick_by did not bring a Tick before the next regular Tick would have come");
        k.finish();
    }
}

// --- 502: two libraries with different deadlines ----------------------------------------------------------------------

fn c_tick_by_two_deadlines<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    // k.n and k.m are the two libraries' next deadlines; k.p and k.q count the Ticks that served each
    if k.step == 0 {
        k.within(io, 5000);
        k.step = 1;
    } else {
        let t = tick_time(ev);
        if t >= 0 && k.step == 1 {
            k.n = t + 20;
            k.m = t + 50;
            k.started = t;
            io.tick_by(k.n);
            io.tick_by(k.m);
            k.step = 2;
        } else if t >= 0 {
            if t >= k.n {
                k.expect(t < k.n + 100, "a library whose deadline had passed did not get a Tick before the next regular Tick");
                k.n = t + 20;
                k.p++;
            }
            if t >= k.m {
                k.expect(t < k.m + 100, "the other library's deadline was not served before the next regular Tick");
                k.m = t + 50;
                k.q++;
            }
            // each library asks again for its own deadline while handling every Tick
            io.tick_by(k.n);
            io.tick_by(k.m);
            if t >= k.started + 600 {
                k.expect(k.p >= 24, "a library asking for a Tick every 20 ms was served fewer than 24 times in 600 ms");
                k.expect(k.q >= 10, "a library asking for a Tick every 50 ms was served fewer than 10 times in 600 ms");
                k.finish();
            }
        }
    }
}

// --- 503, 504: PassEnd --------------------------------------------------------------------------------------------------

// k.n: link events since the last PassEnd; k.m: PassEnds seen; k.t: link events seen
fn pass_end_rules(k: Case&, ev: goose_io::Event) {
    match ev {
        PassEnd => {
            k.expect(k.n > 0, "a PassEnd was delivered with no link event since the last one");
            k.n = 0;
            k.m++;
        },
        Tick t => {
            k.expect(k.n == 0, "a Tick came after link events with no PassEnd between");
        },
        _ => { if k.is_mine(ev) { k.n++; k.t++; } },
    }
}

fn c_pass_end_follows_link_events<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.step = 1;
    } else {
        if k.step >= 1 { pass_end_rules(k, ev); }
        if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
            // two sends in one handler: the replies they cause may be batched
            io.send(k.link[0], "one");
            io.send(k.link[2], "two");
            k.step = 2;
        } else if k.step == 2 && k.received(1).len >= 3 && k.received(3).len >= 3 {
            io.close(k.link[0]);
            io.close(k.link[2]);
            k.step = 3;
        } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(2, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(3, 'C') >= 0 {
            k.expect(k.m >= 1, "no PassEnd was delivered for a pass that delivered link events");
            k.step = 4;
            k.t = io.now_ms();
        } else if k.step == 4 && io.now_ms() >= k.t + 100 {
            k.finish();
        }
    }
}

fn c_pass_end_not_on_idle_pass<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.within(io, 5000);
        k.t = io.now_ms();
        k.step = 1;
    } else {
        match ev {
            PassEnd => { k.expect(false, "a PassEnd was delivered on a pass that delivered only a Tick or nothing"); },
            _ => {},
        }
        if io.now_ms() >= k.t + 500 { k.finish(); }
    }
}

// --- 505: stop with nothing open ------------------------------------------------------------------------------------------

fn c_stop_with_nothing_open<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(io.now_ms() < k.t + 5000, "serve waited for the grace period although no link was open");
        k.finish();
    } else if k.step == 0 {
        k.expect(!io.draining(), "draining was true before stop");
        k.t = io.now_ms();
        io.stop(5000);
        k.expect(io.draining(), "draining was false after stop");
        let l, err = io.listen("127.0.0.1:0", k.tag(0));
        k.expect(!goose_io::is_listener(l) && goose_io::failed(err), "listen succeeded after stop");
        k.step = 1;
    }
}

// --- parts 1 to 5: stop ---------------------------------------------------------------------------------------------------------

// Stop with a link that stays open: its Closed carries Shutdown once the grace period has passed.
fn c_stop_link_stays_open<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(k.flag, "the links were not closed by the end of the grace period before serve returned");
        k.expect(io.now_ms() >= k.t + 2000, "serve returned before the grace period had passed");
        k.finish();
    } else if k.step == 0 {
        k.connect_local(io, 0);
        k.within(io, 20000);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.t = io.now_ms();
        io.stop(2000);
        k.step = 2;
    } else if k.step == 2 {
        k.expect(io.draining(), "draining was false in a later handler");
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
            k.expect(k.closed_with(0, goose_io::CloseReason.Shutdown) && k.closed_with(1, goose_io::CloseReason.Shutdown), "links open at the end of the grace period did not close with Shutdown");
            k.expect(k.recs[k.first(0, 'C')].at >= k.t + 2000, "a link closed with Shutdown before the grace period had passed");
            k.flag = true;
            k.step = 3;
        }
    }
}

// Libraries finish: the links are closed on seeing draining, and serve returns without waiting out the grace period.
fn c_stop_libraries_finish<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(k.flag, "the links did not close");
        k.expect(io.now_ms() < k.t + 5000, "serve waited for the grace period after the last Closed");
        k.finish();
    } else if k.step == 0 {
        k.connect_local(io, 0);
        k.within(io, 20000);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.t = io.now_ms();
        io.stop(5000);
        k.step = 2;
    } else if k.step == 2 {
        if io.draining() { io.close(k.link[0]); io.close(k.link[1]); }
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 { k.flag = true; k.step = 3; }
    }
}

// Listening while draining fails, and the loop still ends at the end of the grace period.
fn c_listen_while_draining<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(k.flag, "the link did not close");
        k.finish();
    } else if k.step == 0 {
        k.connect_local(io, 0);
        k.within(io, 20000);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.stop(1000);
        let l, err = io.listen("127.0.0.1:0", k.tag(2));
        k.expect(!goose_io::is_listener(l), "listen after stop returned a listener");
        k.expect(goose_io::failed(err), "listen after stop did not return an error");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.flag = true;
        k.step = 3;
    }
}

// Dialling while draining still ends in exactly one event; a link that opens ends with Shutdown at the end of the
// grace period and does not extend it.
fn c_dial_while_draining<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(k.flag, "the dial did not end");
        k.expect(io.now_ms() <= k.t + 300 + 100, "a link dialled while draining extended the grace period");
        k.finish();
    } else if k.step == 0 {
        k.connect_local(io, 0);
        k.within(io, 20000);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.t = io.now_ms();
        io.stop(300);
        // dial the address that answers while draining if the fixture has one, else the stopped listener
        if fx.answers.len > 0 { k.dial_to(io, fx.answers, 1, 0); } else { k.dial_local(io, 1, 0); }
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 {
        k.expect(k.count(2, 'C') == 1, "a dial made while draining did not end in exactly one Closed");
        if k.first(2, 'O') >= 0 {
            k.expect(k.closed_with(2, goose_io::CloseReason.Shutdown), "a link opened while draining did not close with Shutdown");
            k.expect(k.recs[k.first(2, 'C')].at <= k.t + 300 + 100, "a link opened while draining outlived the grace period");
        } else {
            k.expect(fx.answers.len == 0, "a dial to the address that answers while draining did not open");
        }
        k.flag = true;
        k.step = 3;
    }
}

// Stop called twice: the earliest end of grace stands.
fn c_stop_called_twice<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.after {
        k.expect(k.flag, "the links did not close");
        k.finish();
    } else if k.step == 0 {
        k.connect_local(io, 0);
        k.within(io, 20000);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.t = io.now_ms();
        io.stop(300);
        io.stop(5000);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        let at = k.recs[k.first(0, 'C')].at;
        k.expect(at >= k.t + 300, "the links closed before the first grace period had passed");
        k.expect(at < k.t + 1000, "a second stop with a longer grace period postponed the first");
        k.expect(k.closed_with(0, goose_io::CloseReason.Shutdown), "the links did not close with Shutdown");
        k.flag = true;
        k.step = 3;
    }
}

// Runs the checks of the core: true if the check is one of them.
fn time_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 500 { c_ticks_are_regular(k, io, ev); return true; }
    if k.id == 501 { c_tick_by_is_prompt(k, io, ev); return true; }
    if k.id == 502 { c_tick_by_two_deadlines(k, io, ev); return true; }
    if k.id == 505 { c_stop_with_nothing_open(k, io, ev); return true; }
    if k.id == 510 { c_stop_link_stays_open(k, io, ev); return true; }
    if k.id == 520 { c_stop_libraries_finish(k, io, ev); return true; }
    if k.id == 530 { c_listen_while_draining(k, io, ev); return true; }
    if k.id == 540 { c_dial_while_draining(k, fx, io, ev); return true; }
    if k.id == 550 { c_stop_called_twice(k, io, ev); return true; }
    return false;
}

// Runs the checks of the batching group: true if the check is one of them.
fn time_batching_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 503 { c_pass_end_follows_link_events(k, io, ev); return true; }
    if k.id == 504 { c_pass_end_not_on_idle_pass(k, io, ev); return true; }
    return false;
}

// Runs the checks not yet assigned to a group (tasks 4.2 to 4.4): true if the check is one of them.
fn time_rest_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    return false;
}
