// goose-io conformance suite, wake capability: `waker`, `wake` and `Woken`.
// Requirement: Wakes are delivered in order and lost by no pass. Wakes from other threads are unit tests (the suite runs on the loop's thread).
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn wake_info(id: i64) -> Info {
    if id == 650 { return Info { name: "wake_in_order", req: "Wakes are delivered in order and lost by no pass", part: 0 }; }
    if id == 651 { return Info { name: "wake_carries_body", req: "A wake can carry a body of up to 64 bytes, delivered with its value", part: 0 }; }
    return Info { .. };
}

fn c_wake_in_order<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let w = io.waker();
        io.wake(w, 1);
        io.wake(w, 2);
        io.wake(w, 3);
        k.step = 1;
    } else if k.step == 1 && k.count(-1, 'K') >= 3 {
        var seen: i64[>..] = [];
        for e in k.recs { if e.kind == 'K' { seen.push(e.len); } }
        k.expect(seen.len == 3 && seen[0] == 1 && seen[1] == 2 && seen[2] == 3, "the wakes were not delivered once each, in order");
        k.finish();
    }
}

fn c_wake_carries_body<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let w = io.waker();
        io.wake_with(w, 7, "tag=3 until=900");
        io.wake_with(w, 8, "");
        io.wake(w, 9);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Woken w => {
                if w.value == 7 { k.expect(w.body[..] == "tag=3 until=900", "wake_with delivered a different body"); }
                else if w.value == 8 || w.value == 9 { k.expect(w.body.len == 0, "a wake without a body delivered one"); }
                if w.value == 9 { k.finish(); }
            },
            _ => {},
        }
    }
}

fn wake_capability_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 650 { c_wake_in_order(k, io, ev); return true; }
    if k.id == 651 { c_wake_carries_body(k, io, ev); return true; }
    return false;
}
