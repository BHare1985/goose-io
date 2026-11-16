// The driver's guard against re-entrancy, shown to work. Every check runs under it: an event delivered from
// inside the handler of another fails the check that is running. A queue-based provider cannot be made to
// re-enter (an operation has no handler to call), so the check events_not_reentrant has no fault in the
// provider; here the nesting is made by hand: the driver is told a handler is already running.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    var g = goose_io_conformance::CoreGroup { .. };
    var d = goose_io_conformance::Driver { part: 0, .. };
    var k = goose_io_conformance::Case { .. };
    d.ids.push(104);                                   // order_accepted_link: a check that needs several events
    let fx = goose_io_conformance::Fixture { .. };
    let tick: goose_io::Event = goose_io::Event.Tick { now_ms: 0 };
    goose_io_conformance::_drive(g, d, k, fx, io, tick);          // begins the check
    kit::check(d.running && k.verdict == goose_io_conformance::RUNNING, "fixture: the check is running");
    d.depth = 1;                                       // as if the provider delivered this event from inside another handler
    goose_io_conformance::_drive(g, d, k, fx, io, tick);
    kit::check(k.verdict == goose_io_conformance::FAILED, "an event delivered inside another handler fails the running check");
    kit::finish();
}
