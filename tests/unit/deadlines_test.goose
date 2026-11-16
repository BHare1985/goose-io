// Deadlines: a bounded min-heap of (time, id) for libraries with many deadlines.
import std;
import goose_io from "../..";
import goose_io.deadlines;
import goose_io.tests.support.kit;

fn order() {
    var d = goose_io::Deadlines { .. };
    kit::check(d.is_empty() && d.next_at() == -1, "a new set is empty and has no next time");
    d.add(300, 3);
    d.add(100, 1);
    d.add(200, 2);
    d.add(200, 7);                  // the same time as another: the lower id comes first
    kit::check(d.count() == 4 && d.next_at() == 100, "four deadlines, the earliest is 100");
    kit::check(d.earliest().id == 1, "earliest names the id of the earliest");
    let none = d.pop_due(99);
    kit::check(!none.found, "nothing is due before the earliest time");
    let a = d.pop_due(250);
    kit::check(a.found && a.id == 1 && a.at_ms == 100, "pop_due gives the earliest that is due");
    let b = d.pop_due(250);
    kit::check(b.found && b.id == 2, "then the next, by time and then by id");
    let c = d.pop_due(250);
    kit::check(c.found && c.id == 7, "and the one with the same time and the higher id");
    kit::check(!d.pop_due(250).found && d.count() == 1 && d.next_at() == 300, "one that is not due stays");
    kit::check(d.pop_due(300).id == 3 && d.is_empty(), "and goes when its time comes");
}

fn cancelling() {
    var d = goose_io::Deadlines { .. };
    for i in 10 { d.add(1000 - i * 10, i as u32 + 1); }      // ids 1..10 at 1000, 990, ..., 910
    kit::check(d.next_at() == 910, "fixture: the earliest is id 10");
    kit::check(d.cancel(10), "cancel of the earliest by id succeeds");
    kit::check(d.next_at() == 920 && d.earliest().id == 9, "the next earliest takes its place");
    kit::check(d.cancel(5) && !d.cancel(5), "cancel of a middle one succeeds once");
    kit::check(!d.cancel(99), "cancel of an id that is not there does nothing");
    kit::check(d.count() == 8, "eight remain");
    var last = -1;
    var ok = true;
    for i in 8 {
        let x = d.pop_due(5000);
        if !x.found || x.at_ms < last { ok = false; }
        last = x.at_ms;
    }
    kit::check(ok && d.is_empty(), "the rest come out in time order");

    // adding an id that is there again moves it
    d.add(500, 1);
    d.add(100, 1);
    kit::check(d.count() == 1 && d.next_at() == 100, "adding an id again moves its deadline");
}

fn bounded() {
    var d = goose_io::Deadlines { .. };
    var all = true;
    for i in goose_io::DEADLINES_MAX { if !d.add(i * 2 + 5000, i as u32 + 1) { all = false; } }
    kit::check(all && d.count() == goose_io::DEADLINES_MAX, "the set takes as many deadlines as its bound");
    kit::check(!d.add(1, 99999), "one more is refused, and nothing changes");
    kit::check(d.count() == goose_io::DEADLINES_MAX && d.next_at() == 5000, "the refused deadline left no trace");
    kit::check(d.cancel(1) && d.next_at() == 5002, "cancelling the earliest of a full set");
    kit::check(d.add(1, 99999) && d.next_at() == 1, "makes room for a new, earlier one");
    var last = -1;
    var ok = true;
    var n = 0;
    loop {
        let x = d.pop_due(1000000);
        if !x.found { break; }
        if x.at_ms < last { ok = false; }
        last = x.at_ms;
        n++;
    }
    kit::check(ok && n == goose_io::DEADLINES_MAX, "a full set comes out in order");
}

fn main() {
    order();
    cancelling();
    bounded();
    kit::finish();
}
