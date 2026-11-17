// The conformance driver: a passing check and a failing one give the return value the entry point promises.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;
import goose_io.tests.support.kit;

// --- the driver's record of every handle it is given (specs/provider-conformance: *The suite checks how handles are issued*) ---

fn lk(slot: u32, gen: u32) -> goose_io::Link { goose_io::Link { slot: slot, gen: gen } }

fn closed_of(l: goose_io::Link) -> goose_io::Event { goose_io::Event.Closed { link: l, why: goose_io::CloseReason.Local } }

fn opened_of(l: goose_io::Link, accepted: bool) -> goose_io::Event {
    goose_io::Event.Opened { link: l, listener: if accepted { goose_io::Listener { id: 1 } } else { goose_io::Listener { .. } } }
}

fn text_has(text: const u8[:], part: const u8[:]) -> bool {
    if part.len > text.len { return false; }
    for i in text.len - part.len + 1 { if text[i..i + part.len] == part { return true; } }
    return false;
}

fn handle_records() {
    // a pair seen again after its Closed fails handles_pair_unique and names the slot and the generation
    var a = goose_io_conformance::Case { .. };
    a.reset(0);
    a.issued(lk(3, 1));
    a.sight(closed_of(lk(3, 1)));
    a.issued(lk(3, 1));
    kit::check(a.pair_bad && !a.slot_bad, "a pair issued again after its Closed fails the pair rule only");
    kit::check(text_has(a.pair_why[..], "slot 3") && text_has(a.pair_why[..], "generation 1"), "and the report names the slot and the generation");

    // a link of generation 0 fails handles_pair_unique
    var b = goose_io_conformance::Case { .. };
    b.reset(0);
    b.issued(lk(2, 0));
    kit::check(b.pair_bad, "a link with generation 0 fails the pair rule");

    // a new pair in a slot whose previous link has not had its Closed fails handles_slot_held
    var c = goose_io_conformance::Case { .. };
    c.reset(0);
    c.issued(lk(5, 1));
    c.issued(lk(5, 2));
    kit::check(c.slot_bad && !c.pair_bad, "a new pair in a slot whose Closed is pending fails the slot rule only");
    kit::check(text_has(c.slot_why[..], "slot 5"), "and the report names the slot");

    // a dialled handle followed by its Opened is one issuance; so is a reuse after a Closed with a new generation
    var d = goose_io_conformance::Case { .. };
    d.reset(0);
    d.issued(lk(1, 1));
    d.sight(opened_of(lk(1, 1), false));
    d.sight(closed_of(lk(1, 1)));
    d.issued(lk(1, 2));
    d.sight(opened_of(lk(1, 2), false));
    d.sight(opened_of(lk(2, 1), true));
    kit::check(!d.pair_bad && !d.slot_bad, "a dialled handle and its Opened are one issuance, and a slot reused after its Closed is fine");

    // the records survive from one check to the next in a part
    d.reset(1);
    d.issued(lk(1, 2));
    kit::check(d.pair_bad, "a pair issued in a later check of the same part is the same pair");
}

// --- the entry point sets the loop up before serve (specs/provider-conformance: *The suite checks the life of a loop*) ---------

fn setup_before_serve() {
    var ok = goose_io_memory::Loop { .. };
    let fx = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9" };
    ok.silent("10.255.0.1:81");
    ok.hold("127.0.0.1:9999");
    kit::check(goose_io_conformance::conformance_core_part(ok, fx, 0) == 0, "a loop that delivers what was set up before serve passes the core part");
    var dropped = goose_io_memory::Loop { .. };
    dropped.silent("10.255.0.1:81");
    dropped.hold("127.0.0.1:9999");
    dropped.set_fault("SetupEventsDropped");
    kit::check(goose_io_conformance::conformance_core_part(dropped, fx, 0) > 0, "a loop that drops the events of what was set up before serve fails the core part");
}

fn main() {
    setup_before_serve();
    handle_records();
    var io = goose_io_memory::Loop { .. };
    let fx = goose_io_conformance::Fixture { .. };
    let failed = goose_io_conformance::conformance_core_part(io, fx, -1);
    kit::check(failed == 1, "one check passes and one fails on purpose: the entry point returns 1");
    kit::finish();
}
