// goose-io conformance suite: the driver and the entry point.
//
// The suite is written only against the contract. Both ends of every link are on the provider under test:
// a check listens and dials on the same loop and makes the peer's behaviour with contract calls (`reset`,
// `shutdown_write`, `pause_reading`, not sending). What calls cannot produce, an address that never answers
// and an address that is held, the runner supplies in a Fixture.
//
// A provider's root program is about ten lines (docs/providers.md):
//
//     import goose_io from "../..";
//     import goose_io.conformance.suite;
//     import goose_io.memory;
//     fn main() {
//         var io = goose_io_memory::Loop { .. };
//         io.silent("10.255.0.1:81");
//         io.hold("127.0.0.1:9999");
//         let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999" };
//         exit(goose_io_conformance::conformance_part(io, fixture, 0));
//     }
//
// Only one `stop` can be observed in one `serve`, so the suite is divided into parts and each part is run
// by its own process: part 0 is every check that does not need `stop` and ends with "stop with nothing
// open"; each other part is one scenario of `stop`. `conformance_parts()` is the number of parts.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.selftest;
import conformance.handles;
import conformance.net;
import conformance.data;
import conformance.close;
import conformance.time;

// Part -1 holds two checks that exist to test the driver: one passes and one fails on purpose.
let SELFTEST = -1;

fn info(id: i64) -> Info {
    var i = selftest_info(id);
    if i.name.len == 0 { i = handles_info(id); }
    if i.name.len == 0 { i = net_info(id); }
    if i.name.len == 0 { i = data_info(id); }
    if i.name.len == 0 { i = close_info(id); }
    if i.name.len == 0 { i = time_info(id); }
    i.group = group_of(i.name);
    return i;
}

// The group a check belongs to: the group whose operation or event is its subject. A check not named here has not
// been assigned yet (GROUP_PENDING).
fn group_of(name: const u8[:]) -> i64 {
    if name.len == 0 { return GROUP_CORE; }
    if name == "selftest_pass" || name == "selftest_fail" { return GROUP_CORE; }
    if name == "close_after_reply" || name == "close_cancels_a_dial" || name == "close_with_unread_input" || name == "close_when_peer_never_reads" || name == "data_arrives_as_slices" || name == "send_copies_at_once" || name == "send_is_bounded" || name == "writable_once_for_many_refusals" || name == "writable_next_episode" || name == "pause_and_resume_reading" || name == "order_accepted_link" || name == "owner_tags" || name == "owner_user_value" || name == "owner_user_after_failed_dial" || name == "listen_accepts" || name == "listen_held_address" || name == "dial_succeeds" || name == "dial_times_out" || name == "dial_bad_address" || name == "ticks_are_regular" || name == "tick_by_is_prompt" || name == "tick_by_two_deadlines" || name == "stop_with_nothing_open" || name == "stop_link_stays_open" || name == "stop_libraries_finish" || name == "listen_while_draining" || name == "dial_while_draining" || name == "stop_called_twice" { return GROUP_CORE; }
    if name == "pass_end_follows_link_events" || name == "pass_end_not_on_idle_pass" { return GROUP_BATCHING; }
    return GROUP_PENDING;
}

// What a check of each group is run by: the functions `step` runs the check whose id the case holds, and `takes` says
// whether a check belongs to the suite being run.
fn step<Io>(g: CoreGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if selftest_step(k, fx, io, ev) { return; }
    if handles_core_step(k, fx, io, ev) { return; }
    if net_core_step(k, fx, io, ev) { return; }
    if data_core_step(k, fx, io, ev) { return; }
    if close_core_step(k, fx, io, ev) { return; }
    if time_core_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: BatchingGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if time_batching_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

// Transitional: every check, as the suite was before it was split by group.
fn step<Io>(g: AllGroups&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if selftest_step(k, fx, io, ev) { return; }
    if handles_core_step(k, fx, io, ev) || handles_rest_step(k, fx, io, ev) { return; }
    if net_core_step(k, fx, io, ev) || net_rest_step(k, fx, io, ev) { return; }
    if data_core_step(k, fx, io, ev) || data_rest_step(k, fx, io, ev) { return; }
    if close_core_step(k, fx, io, ev) || close_rest_step(k, fx, io, ev) { return; }
    if time_core_step(k, fx, io, ev) || time_batching_step(k, fx, io, ev) || time_rest_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn takes(g: CoreGroup&, i: Info) -> bool { i.group == GROUP_CORE }
fn takes(g: BatchingGroup&, i: Info) -> bool { i.group == GROUP_BATCHING }
fn takes(g: AllGroups&, i: Info) -> bool { true }

// The number of parts: 0 and one for each `stop` scenario.
fn conformance_parts() -> i64 { 6 }

struct Driver {
    part:     i64      = 0,
    pos:      i64      = 0,
    running:  bool     = false,
    depth:    i64      = 0,
    failures: i64      = 0,
    ran:      i64      = 0,
    stopped:  bool     = false,
    ids:      i64[>..] = [],     // resizable fields come last
}

fn _report(d: Driver&, k: Case&) {
    let i = info(k.id);
    d.ran++;
    if k.verdict == FAILED {
        d.failures++;
        print("FAIL ", i.name, " [", i.req, "]: ", k.why);
    } else {
        print("ok   ", i.name);
    }
}

fn _begin<Io, G>(g: G&, d: Driver&, k: Case&, fx: Fixture, io: Io&) {
    k.reset(d.ids[d.pos], (d.pos + 1) * TAGS_PER_CHECK);
    d.running = true;
    k.within(io, 10000);
    let start: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
    g.step(k, fx, io, start);
}

fn _drive<Io, G>(g: G&, d: Driver&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    d.depth++;
    if d.depth > 1 && d.running { k.fail("an event was delivered from inside the handler of another event"); }
    if d.pos >= d.ids.len {
        if !d.stopped { d.stopped = true; io.stop(0); }
        d.depth--;
        return;
    }
    if !d.running { g._begin(d, k, fx, io); }
    k.track(io, ev);
    g.step(k, fx, io, ev);
    if k.verdict == RUNNING && io.now_ms() >= k.deadline {
        k.fail("not finished in time on the loop's clock");
    }
    // a check ends when it has failed, or when it is finished and every link it made has closed
    if k.verdict == FAILED || (k.done && k.live <= 0) {
        if k.verdict == RUNNING { k.verdict = PASSED; }
        d._report(k);
        d.pos++;
        d.running = false;
        if d.pos < d.ids.len { g._begin(d, k, fx, io); }
    }
    d.depth--;
}

// Runs one part of the suite for one group on `io`. Returns the number of checks that failed and prints one line for
// each check, naming a failed check and the requirement it proves.
fn _run_part<Io, G>(g: G&, io: Io&, fx: Fixture, part: i64) -> i32 {
    var d = Driver { part: part, .. };
    var k = Case { .. };
    for id in 1000 {
        let i = info(id);
        if i.name.len > 0 && i.part == part && g.takes(i) { d.ids.push(id); }
    }
    if d.ids.len == 0 { print("FAIL no checks in part ", part); return 1; }
    io.serve() { io, ev => _drive(g, d, k, fx, io, ev); };
    // serve has returned: a check that waited for `stop` to take effect gives its verdict now
    if d.running {
        k.after = true;
        let end: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
        g.step(k, fx, io, end);
        if k.verdict == RUNNING {
            if k.done { k.verdict = PASSED; } else { k.fail("serve returned before the check finished"); }
        }
        d._report(k);
        d.pos++;
    }
    if d.pos < d.ids.len {
        for i in d.ids.len - d.pos {
            print("FAIL ", info(d.ids[d.pos + i]).name, " [", info(d.ids[d.pos + i]).req, "]: serve returned before the check ran");
            d.failures++;
        }
    }
    print(d.ran, " checks run in part ", part, ", ", d.failures, " failed");
    return d.failures as i32;
}

// The checks of the core: what every event loop supplies, and nothing that needs a group.
fn conformance_core_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = CoreGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the batching group (`PassEnd`).
fn conformance_batching_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = BatchingGroup { .. };
    return _run_part(g, io, fx, part);
}

// Transitional: every check in one suite, as before the suite was split by group. Needs an event loop that
// supplies everything. Goes when the checks of every group have their entry point (task 4.4).
fn conformance_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = AllGroups { .. };
    return _run_part(g, io, fx, part);
}
