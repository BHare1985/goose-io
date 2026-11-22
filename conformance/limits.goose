// goose-io conformance suite, limits group: `set_limit` and `Expired`.
// Requirements: A limit tells the library that a link has run too long in a state; Idle, Silent and Age measure quiet and lifetime;
// Stalled bounds a link whose peer does not read; A half-closed link is bounded; Expired reports and the library decides.
// Every check works on pair 0; times are small so that a loop on the real clock runs the group in a few seconds.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.data;

fn limits_info(id: i64) -> Info {
    if id == 660 { return Info { name: "limit_idle_and_age", req: "A limit tells the library that a link has run too long in a state", part: 0 }; }
    if id == 661 { return Info { name: "limit_replace_and_off", req: "A limit tells the library that a link has run too long in a state", part: 0 }; }
    if id == 662 { return Info { name: "limit_idle_activity_moves", req: "Idle, Silent and Age measure quiet and lifetime", part: 0 }; }
    if id == 663 { return Info { name: "limit_silent_while_sending", req: "Idle, Silent and Age measure quiet and lifetime", part: 0 }; }
    if id == 664 { return Info { name: "limit_age_not_moved", req: "Idle, Silent and Age measure quiet and lifetime", part: 0 }; }
    if id == 665 { return Info { name: "limit_stalled_never_reads", req: "Stalled bounds a link whose peer does not read", part: 0 }; }
    if id == 666 { return Info { name: "limit_stalled_slow_reader", req: "Stalled bounds a link whose peer does not read", part: 0 }; }
    if id == 667 { return Info { name: "limit_stalled_nothing_waits", req: "Stalled bounds a link whose peer does not read", part: 0 }; }
    if id == 668 { return Info { name: "limit_halfopen_not_ended", req: "A half-closed link is bounded", part: 0 }; }
    if id == 669 { return Info { name: "limit_one_event_per_arming", req: "Expired reports and the library decides", part: 0 }; }
    if id == 670 { return Info { name: "limit_closed_link", req: "Expired reports and the library decides", part: 0 }; }
    return Info { .. };
}

// Starts a check on pair 0 and returns true once both ends are open (step 1); the check's own work begins at step 2.
fn limits_ready<Io>(k: Case&, io: Io&) -> bool {
    if k.step == 0 { k.connect_local(io, 0); k.step = 1; return false; }
    if k.step == 1 && k.pair_open(0) { k.t = io.now_ms(); k.step = 2; return true; }
    return false;
}

// Gives the loop a reason to run until `at`.
fn wait_until<Io>(k: Case&, io: Io&, at: i64) -> bool {
    if io.now_ms() >= at { return true; }
    io.tick_by(at);
    return false;
}

fn expired_at(k: Case&, role: i64, n: i64) -> i64 {
    var seen = 0;
    for e in k.recs { if e.role == role && e.kind == 'X' { if seen == n { return e.at; } seen++; } }
    return -1;
}

fn expired_kind(k: Case&, role: i64, n: i64) -> i64 {
    var seen = 0;
    for e in k.recs { if e.role == role && e.kind == 'X' { if seen == n { return e.off; } seen++; } }
    return -1;
}

fn c_limit_idle_and_age<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Idle, 1000);
        io.set_limit(k.link[1], goose_io::Limit.Age, 2500);
        io.tick_by(k.t + 4500);
    } else if k.step == 2 && io.now_ms() >= k.t + 4500 {
        let base = k.recs[k.first(1, 'O')].at;
        k.expect(k.count(1, 'X') == 2, "two limits on one link did not give exactly two Expired");
        k.expect(expired_kind(k, 1, 0) == 0 && expired_kind(k, 1, 1) == 4, "the Expired were not Idle and then Age");
        k.expect(expired_at(k, 1, 0) >= k.t + 1000, "Idle expired before its time");
        k.expect(expired_at(k, 1, 1) >= base + 2500, "Age expired before its time");
        k.expect(k.first(1, 'C') < 0, "the loop closed a link whose limit expired");
        k.step = 3;
        io.close(k.link[1]);
        k.finish();
    }
}

fn c_limit_replace_and_off<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Idle, 1000);
        io.set_limit(k.link[1], goose_io::Limit.Idle, 4000);
        io.tick_by(k.t + 2000);
    } else if k.step == 2 && io.now_ms() >= k.t + 2000 {
        k.expect(k.count(1, 'X') == 0, "a replaced limit expired at its first time");
        io.set_limit(k.link[1], goose_io::Limit.Idle, 300);
        io.set_limit(k.link[1], goose_io::Limit.Idle, 0);
        k.t = io.now_ms();
        io.tick_by(k.t + 1200);
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 1200 {
        k.expect(k.count(1, 'X') == 0, "a limit turned off expired");
        io.close(k.link[1]);
        k.finish();
    }
}

fn c_limit_idle_activity_moves<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Idle, 1000);
        io.tick_by(k.t + 400);
    } else if k.step == 2 {
        if k.n < 4 && io.now_ms() >= k.t + 400 * (k.n + 1) {
            io.send(k.link[0], "x");
            k.n++;
            k.p = io.now_ms();
        }
        if k.n < 4 { io.tick_by(k.t + 400 * (k.n + 1)); }
        else {
            k.expect(k.count(1, 'X') == 0, "Idle expired while bytes kept arriving");
            k.step = 3;
        }
    } else if k.step == 3 && k.count(1, 'X') > 0 {
        k.expect(k.recs[k.first(1, 'X')].at >= k.p + 1000, "Idle expired less than its time after the last byte");
        io.close(k.link[1]);
        k.finish();
    }
}

fn c_limit_silent_while_sending<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Silent, 1000);
        io.tick_by(k.t + 300);
    } else if k.step == 2 {
        if k.n < 5 && io.now_ms() >= k.t + 300 * (k.n + 1) {
            io.send(k.link[1], "x");
            k.n++;
        }
        if io.now_ms() >= k.t + 1500 {
            k.expect(k.count(1, 'X') == 1 && expired_kind(k, 1, 0) == 1, "Silent did not expire while the library sent and nothing was received");
            io.close(k.link[1]);
            k.finish();
        } else { io.tick_by(k.t + 300 * (k.n + 1)); }
    }
}

fn c_limit_age_not_moved<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Age, 1500);
        io.tick_by(k.t + 300);
    } else if k.step == 2 {
        if k.n < 7 && io.now_ms() >= k.t + 300 * (k.n + 1) {
            io.send(k.link[0], "x");
            k.n++;
        }
        if io.now_ms() >= k.t + 2300 {
            k.expect(k.count(1, 'X') == 1 && expired_kind(k, 1, 0) == 4, "Age did not expire on time while bytes kept arriving");
            io.close(k.link[1]);
            k.finish();
        } else { io.tick_by(k.t + 300 * (k.n + 1)); }
    }
}

fn c_limit_stalled_never_reads<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.pause_reading(k.link[1], true);
        fill(io, k.link[0], 64 << 20);
        io.set_limit(k.link[0], goose_io::Limit.Stalled, 1000);
        io.tick_by(k.t + 300);
    } else if k.step == 2 {
        if k.n < 6 && io.now_ms() >= k.t + 300 * (k.n + 1) {
            io.send(k.link[1], "x");     // bytes the stalled link reads are not progress in writing
            k.n++;
        }
        if io.now_ms() >= k.t + 2200 {
            k.expect(k.count(0, 'X') == 1 && expired_kind(k, 0, 0) == 2, "Stalled did not expire for a peer that never reads");
            io.pause_reading(k.link[1], false);
            io.close(k.link[0]);
            k.finish();
        } else { io.tick_by(k.t + 300 * (k.n + 1)); }
    }
}

fn c_limit_stalled_slow_reader<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.pause_reading(k.link[1], true);
        fill(io, k.link[0], 64 << 20);
        io.set_limit(k.link[0], goose_io::Limit.Stalled, 1000);
        k.p = io.now_ms();
        io.tick_by(k.t + 400);
    } else if k.step == 2 {
        // every 400 ms the peer reads for 100 ms and is then paused again, while the library keeps its link full (a real transport
        // releases its send buffer in lumps, so a single read per cycle is not progress it can be relied on to show)
        if k.flag && io.now_ms() >= k.p + 100 {
            io.pause_reading(k.link[1], true);
            fill(io, k.link[0], 64 << 20);
            k.flag = false;
        } else if io.now_ms() >= k.p + 400 {
            io.pause_reading(k.link[1], false);
            k.p = io.now_ms();
            k.flag = true;
        }
        if io.now_ms() >= k.t + 2500 {
            k.expect(k.count(0, 'X') == 0, "Stalled expired for a peer that kept reading");
            io.pause_reading(k.link[1], false);
            io.close(k.link[0]);
            k.finish();
        } else { io.tick_by(k.p + (if k.flag { 100 } else { 400 })); }
    }
}

fn c_limit_stalled_nothing_waits<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[0], goose_io::Limit.Stalled, 1000);
        io.tick_by(k.t + 2000);
    } else if k.step == 2 && io.now_ms() >= k.t + 2000 {
        k.expect(k.count(0, 'X') == 0, "Stalled expired on a link with nothing waiting to be sent");
        io.close(k.link[0]);
        k.finish();
    }
}

fn c_limit_halfopen_not_ended<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.HalfOpen, 1000);
        io.tick_by(k.t + 2000);
    } else if k.step == 2 && io.now_ms() >= k.t + 2000 {
        k.expect(k.count(1, 'X') == 0, "HalfOpen expired on a link whose peer had not ended its stream");
        io.close(k.link[1]);
        k.finish();
    }
}

fn c_limit_one_event_per_arming<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        io.set_limit(k.link[1], goose_io::Limit.Idle, 500);
        io.tick_by(k.t + 2000);
    } else if k.step == 2 && io.now_ms() >= k.t + 2000 {
        k.expect(k.count(1, 'X') == 1, "a limit was not reported exactly once for one arming");
        io.set_limit(k.link[1], goose_io::Limit.Idle, 500);
        k.t = io.now_ms();
        io.tick_by(k.t + 1500);
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 1500 {
        k.expect(k.count(1, 'X') == 2, "arming a limit again did not give one more Expired");
        io.close(k.link[1]);
        k.finish();
    }
}

fn c_limit_closed_link<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if limits_ready(k, io) {
        // two limits fall due in one pass; the library closes the link in the handler of the first
        io.set_limit(k.link[1], goose_io::Limit.Idle, 800);
        io.set_limit(k.link[1], goose_io::Limit.Age, 800);
        io.tick_by(k.t + 2000);
    } else if k.step == 2 && k.count(1, 'X') == 1 {
        io.close(k.link[1]);
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 2000 {
        k.expect(k.count(1, 'X') == 1, "Expired was delivered for a link that was closing");
        k.finish();
    } else if k.step == 3 {
        io.tick_by(k.t + 2000);
    }
}

fn limits_group_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 660 { c_limit_idle_and_age(k, io, ev); return true; }
    if k.id == 661 { c_limit_replace_and_off(k, io, ev); return true; }
    if k.id == 662 { c_limit_idle_activity_moves(k, io, ev); return true; }
    if k.id == 663 { c_limit_silent_while_sending(k, io, ev); return true; }
    if k.id == 664 { c_limit_age_not_moved(k, io, ev); return true; }
    if k.id == 665 { c_limit_stalled_never_reads(k, io, ev); return true; }
    if k.id == 666 { c_limit_stalled_slow_reader(k, io, ev); return true; }
    if k.id == 667 { c_limit_stalled_nothing_waits(k, io, ev); return true; }
    if k.id == 668 { c_limit_halfopen_not_ended(k, io, ev); return true; }
    if k.id == 669 { c_limit_one_event_per_arming(k, io, ev); return true; }
    if k.id == 670 { c_limit_closed_link(k, io, ev); return true; }
    return false;
}
