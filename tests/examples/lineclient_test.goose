// examples/lineclient: a pooled, pipelining client for the same newline protocol, written only against the
// contract and run on the in-memory provider with scripted peers: the pool fills to its size, pipelined
// replies are matched in order, a deadline is reported once and a late reply is discarded, an aborted link
// fails each outstanding request once and the client reconnects after its backoff on the virtual clock,
// `Full` and `Writable`, every kind of failed dial, and a close reason only the provider has.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;
import goose_io.examples.lineclient.client;

// What the application saw: results in the order they were reported, with the reply text of each.
struct Got { id: u32 = 0, outcome: u8 = 0, at_ms: i64 = 0, off: i64 = 0, len: i64 = 0 }

root struct App {
    got:          Got[>..]  = [],
    bytes:        u8[>..]   = [],
    plan_at:      i64[>..]  = [],            // requests to make at these times
    plan_bytes:   u8[>..]   = [],
    plan_off:     i64[>..]  = [],
    plan_len:     i64[>..]  = [],
    plan_timeout: i64[>..]  = [],
    plan_done:    bool[>..] = [],
    ids:          u32[>..]  = [],            // the id each planned request got
    stop_at:      i64       = 400,
}

fn plan(a: App&, at_ms: i64, text: const u8[:], timeout_ms: i64) {
    a.plan_at.push(at_ms);
    a.plan_off.push(a.plan_bytes.len);
    a.plan_len.push(text.len);
    a.plan_bytes.append(text);
    a.plan_timeout.push(timeout_ms);
    a.plan_done.push(false);
    a.ids.push(0);
}

fn app_event<Io>(a: App&, c: lineclient::LineClient&, io: Io&, ev: goose_io::Event) {
    c.client_event(io, ev);
    match ev {
        Tick t => {
            for i in a.plan_at.len {
                if !a.plan_done[i] && t.now_ms >= a.plan_at[i] {
                    a.plan_done[i] = true;
                    a.ids[i] = c.request(io, a.plan_bytes[a.plan_off[i]..a.plan_off[i] + a.plan_len[i]], a.plan_timeout[i]);
                }
            }
        },
        _ => {},
    }
    loop {
        var text: u8[>..] = [];
        let r = c.take_result(text);
        if !r.found { break; }
        let off = a.bytes.len;
        a.bytes.append(text[..]);
        a.got.push(Got { id: r.id, outcome: code(r.outcome), at_ms: io.now_ms(), off: off, len: text.len });
    }
    kit::stop_after(io, ev, a.stop_at);
}

fn text_of(a: App&, i: i64) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(a.bytes[a.got[i].off..a.got[i].off + a.got[i].len]);
    return out;
}

fn outcome_of(a: App&, id: u32) -> i64 {
    for g in a.got { if g.id == id { return g.outcome; } }
    return -1;
}

fn results_for(a: App&, id: u32) -> i64 {
    var n = 0;
    for g in a.got { if g.id == id { n++; } }
    return n;
}

let R_OK = 0;
let R_TIMED_OUT = 1;
let R_LINK_LOST = 2;
let R_FAILED = 3;

fn code(o: lineclient::Outcome) -> u8 {
    match o {
        Ok => { return 0; },
        TimedOut => { return 1; },
        LinkLost => { return 2; },
        Failed => { return 3; },
    }
}

fn begin<Io>(c: lineclient::LineClient&, io: Io&, address: const u8[:], pool: i64, backoff_ms: i64) {
    kit::check(c.start(io, address, 7, pool, backoff_ms), "the client starts");
}

// --- the pool fills to its size ---------------------------------------------------------------------

fn pool_fills<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    for i in 3 { let p = io.add_peer(); io.peer_accept(p, "10.0.0.1:6379"); }
    c.begin(io, "10.0.0.1:6379", 3, 100);
    var seen = 0;
    io.serve() { io, ev =>
        app_event(a, c, io, ev);
        match ev { Tick t => { if t.now_ms >= 100 && seen == 0 { seen = c.open_links(); } }, _ => {}, }
    };
    kit::check(seen == 3, "the pool fills to its size");
    kit::check(c.dial_count() == 3, "with one dial for each link");
}

// --- pipelined requests are matched to replies in order --------------------------------------------------

fn pipelined_replies<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.2:6379");
    io.peer_send(p, 300, "reply one\nreply two\n");     // after the requests, which are made at the first Tick, at 100
    io.peer_send(p, 10, "reply three\n");
    c.begin(io, "10.0.0.2:6379", 1, 100);
    a.plan(10, "GET one", 1000);
    a.plan(10, "GET two", 1000);
    a.plan(10, "GET three", 1000);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(io.peer_received(p) == "GET one\nGET two\nGET three\n", "the requests went out on one link, in order, without waiting for replies");
    kit::check(a.got.len == 3, "three results");
    if a.got.len == 3 {
        kit::check(a.got[0].id == a.ids[0] && a.got[1].id == a.ids[1] && a.got[2].id == a.ids[2], "reported in the order of the requests");
        kit::check(text_of(a, 0) == "reply one" && text_of(a, 1) == "reply two" && text_of(a, 2) == "reply three", "each with its own reply");
        kit::check(a.got[0].outcome == R_OK && a.got[1].outcome == R_OK && a.got[2].outcome == R_OK, "all of them Ok");
    }
}

// --- a deadline expires and a late reply is discarded -------------------------------------------------------

fn deadline_expires<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 800;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.3:6379");
    io.peer_send(p, 450, "late reply\n");
    io.peer_send(p, 10, "second reply\n");
    c.begin(io, "10.0.0.3:6379", 1, 100);
    a.plan(10, "first", 100);
    a.plan(250, "second", 2000);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(results_for(a, a.ids[0]) == 1, "an expired request is reported exactly once");
    kit::check(outcome_of(a, a.ids[0]) == R_TIMED_OUT, "as timed out");
    var first_at = -1;
    for g in a.got { if g.id == a.ids[0] { first_at = g.at_ms; } }
    kit::check(first_at >= 110 && first_at <= 250, "when its deadline passed, not before and not at the next regular tick");
    kit::check(outcome_of(a, a.ids[1]) == R_OK, "the next request got a reply");
    var second_text: u8[>..] = [];
    for g, i in a.got { if g.id == a.ids[1] { second_text = text_of(a, i); } }
    kit::check(second_text == "second reply", "and it is its own reply, not the late one");
    kit::check(a.got.len == 2, "the late reply produced no result");
}

// --- an aborted link fails each outstanding request once; the client reconnects after its backoff ------------------

fn lost_link_and_reconnect<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 1500;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.4:6379");
    io.peer_abort(p, 300);                          // 300 ms after the link opens
    let q = io.add_peer();
    io.peer_accept(q, "10.0.0.4:6379");
    io.peer_send(q, 400, "back again\n");
    c.begin(io, "10.0.0.4:6379", 1, 300);
    a.plan(20, "one", 5000);
    a.plan(20, "two", 5000);
    a.plan(20, "three", 5000);
    a.plan(900, "after", 5000);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    for i in 3 { kit::check(results_for(a, a.ids[i]) == 1 && outcome_of(a, a.ids[i]) == R_LINK_LOST, "each outstanding request is failed once when the link is aborted"); }
    kit::check(c.dial_count() == 2, "one dial after the first");
    kit::check(c.last_dial_at() >= 300 + 300, "made after the backoff, on the loop's clock");
    kit::check(outcome_of(a, a.ids[3]) == R_OK, "a later request is sent on the new link");
    kit::check(io.peer_received(q) == "after\n", "and only that one reaches it");
}

// --- Full, then Writable -----------------------------------------------------------------------------------------

fn backpressure<Io>(io: Io&) {
    io.cfg.link_buffer = 4096;
    io.cfg.max_send = 4096;
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 1000;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.5:6379");
    io.peer_stop_reading(p, 0);
    io.peer_resume_reading(p, 200);
    c.begin(io, "10.0.0.5:6379", 1, 100);
    var want: u8[>..] = [];
    for n in 5 {
        var body: u8[>..] = [];
        body.append("SET ");
        for i in 3000 { body.push(('a' + n) as u8); }
        a.plan(10, body[..], 5000);
        want.append(body[..]);
        want.push('\n');
    }
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(c.full_count() > 0, "fixture: the client was refused with Full");
    kit::check(io.peer_received(p) == want, "after Writable every request reached the peer, once, in order");
}

// --- every kind of failed dial -------------------------------------------------------------------------------------------

// Each kind: the client reports it and retries it as it retries Other, except a bad address, which it gives up on.
fn failed_dial_kind<Io>(io: Io&, kind: goose_io::ConnectFailure) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 700;
    io.fail_dials("10.0.1.1:6379", kind);
    c.begin(io, "10.0.1.1:6379", 1, 100);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(c.last_failure() == kind, "the kind of the failed dial is reported");
    kit::check(c.dial_count() >= 3, "and the dial is retried, as Other is");
}

fn refused_dial<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 700;
    c.begin(io, "10.0.1.2:6379", 1, 100);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(c.last_failure() == goose_io::ConnectFailure.Refused && c.dial_count() >= 3, "a refused dial is reported and retried");
}

fn timed_out_dial<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 3000;
    io.silent("10.0.1.3:6379");
    c.begin(io, "10.0.1.3:6379", 1, 100);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(c.last_failure() == goose_io::ConnectFailure.TimedOut && c.dial_count() >= 2, "a dial that timed out is reported and retried");
}

fn bad_address<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 700;
    c.begin(io, "not an address", 1, 100);
    a.plan(10, "x", 500);
    io.serve() { io, ev => app_event(a, c, io, ev); };
    kit::check(c.last_failure() == goose_io::ConnectFailure.BadAddress && c.dial_count() == 1, "a bad address is reported and not retried");
    kit::check(outcome_of(a, a.ids[0]) == R_FAILED, "and a request made meanwhile fails");
}

// --- a close reason only the provider has ------------------------------------------------------------------------------------

fn provider_reason<Io>(io: Io&) {
    var a = App { .. };
    var c = lineclient::LineClient { .. };
    a.stop_at = 900;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.6:6379");
    let q = io.add_peer();
    io.peer_accept(q, "10.0.0.6:6379");
    c.begin(io, "10.0.0.6:6379", 1, 100);
    a.plan(10, "pending", 5000);
    var closed = false;
    io.serve() { io, ev =>
        app_event(a, c, io, ev);
        match ev {
            Tick t => {
                if t.now_ms >= 50 && !closed {
                    closed = true;
                    let l = c.link_of(0);
                    kit::check(goose_io::is_valid(l), "fixture: the pool has a link");
                    io.close_with_reason(l, goose_io::CloseReason.LoopSpecific { code: 77 });
                }
            },
            _ => {},
        }
    };
    kit::check(outcome_of(a, a.ids[0]) == R_LINK_LOST, "a link closed with a provider-specific reason fails its request as an error does");
    kit::check(c.dial_count() == 2, "and is replaced");
}

fn run<Io>(n: i64, io: Io&) {
    if n == 0 { pool_fills(io); }
    if n == 1 { pipelined_replies(io); }
    if n == 2 { deadline_expires(io); }
    if n == 3 { lost_link_and_reconnect(io); }
    if n == 4 { backpressure(io); }
    if n == 5 { failed_dial_kind(io, goose_io::ConnectFailure.Unreachable); }
    if n == 6 { failed_dial_kind(io, goose_io::ConnectFailure.Denied); }
    if n == 7 { failed_dial_kind(io, goose_io::ConnectFailure.NoResources); }
    if n == 8 { failed_dial_kind(io, goose_io::ConnectFailure.Other); }
    if n == 9 { refused_dial(io); }
    if n == 10 { timed_out_dial(io); }
    if n == 11 { bad_address(io); }
    if n == 12 { provider_reason(io); }
}

let SCENARIOS = 13;

// With no argument every scenario runs, each on a loop of its own, on the in-memory provider. With a scenario
// number that scenario runs on the wrapper (tests/examples/over_wrapper.sh runs them all).
fn main() {
    let only = kit::scenario();
    if only >= 0 {
        var w = wrapper::Layer { .. };
        run(only, w);
    } else {
        for n in SCENARIOS {
            var io = goose_io_memory::Loop { .. };
            run(n, io);
        }
    }
    kit::finish();
}
