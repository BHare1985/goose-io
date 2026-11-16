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
    return i;
}

fn run_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if selftest_step(k, fx, io, ev) { return; }
    if handles_step(k, fx, io, ev) { return; }
    if net_step(k, fx, io, ev) { return; }
    if data_step(k, fx, io, ev) { return; }
    if close_step(k, fx, io, ev) { return; }
    if time_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

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

fn _begin<Io>(d: Driver&, k: Case&, fx: Fixture, io: Io&) {
    k.reset(d.ids[d.pos], (d.pos + 1) * TAGS_PER_CHECK);
    d.running = true;
    k.within(io, 10000);
    let start: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
    run_step(k, fx, io, start);
}

fn _drive<Io>(d: Driver&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    d.depth++;
    if d.depth > 1 && d.running { k.fail("an event was delivered from inside the handler of another event"); }
    if d.pos >= d.ids.len {
        if !d.stopped { d.stopped = true; io.stop(0); }
        d.depth--;
        return;
    }
    if !d.running { d._begin(k, fx, io); }
    k.track(io, ev);
    run_step(k, fx, io, ev);
    if k.verdict == RUNNING && io.now_ms() >= k.deadline {
        k.fail("not finished in time on the loop's clock");
    }
    // a check ends when it has failed, or when it is finished and every link it made has closed
    if k.verdict == FAILED || (k.done && k.live <= 0) {
        if k.verdict == RUNNING { k.verdict = PASSED; }
        d._report(k);
        d.pos++;
        d.running = false;
        if d.pos < d.ids.len { d._begin(k, fx, io); }
    }
    d.depth--;
}

// Runs one part of the suite on `io`. Returns the number of checks that failed and prints one line for
// each check, naming a failed check and the requirement it proves.
fn conformance_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var d = Driver { part: part, .. };
    var k = Case { .. };
    for id in 1000 {
        let i = info(id);
        if i.name.len > 0 && i.part == part { d.ids.push(id); }
    }
    if d.ids.len == 0 { print("FAIL no checks in part ", part); return 1; }
    io.serve() { io, ev => _drive(d, k, fx, io, ev); };
    // serve has returned: a check that waited for `stop` to take effect gives its verdict now
    if d.running {
        k.after = true;
        let end: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
        run_step(k, fx, io, end);
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
