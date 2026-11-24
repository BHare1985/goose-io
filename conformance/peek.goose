// goose-io conformance suite, peek capability: `peek`, `wait_input` and `Input`.
// Requirements: Peek waits for enough bytes and then releases them; A link holds a bounded number of unread bytes.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn peek_info(id: i64) -> Info {
    if id == 620 { return Info { name: "wait_input_gathers", req: "Peek waits for enough bytes and then releases them", part: 0 }; }
    if id == 621 { return Info { name: "wait_input_peer_ends", req: "Peek waits for enough bytes and then releases them", part: 0 }; }
    if id == 622 { return Info { name: "peek_bound", req: "A link holds a bounded number of unread bytes", part: 0 }; }
    if id == 623 { return Info { name: "discard_input_drops", req: "Peek waits for enough bytes and then releases them", part: 0 }; }
    return Info { .. };
}

fn c_wait_input_gathers<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.wait_input(k.link[1], 5);
        io.send(k.link[0], "abc");
        k.t = io.now_ms();
        io.tick_by(k.t + 100);
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 100 {
        k.expect(k.count(1, 'I') == 0, "Input was delivered before the bytes asked for had arrived");
        k.expect(k.count(1, 'D') == 0, "Data was delivered while the library waited for input");
        io.send(k.link[0], "defg");
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'I') >= 0 {
        k.expect(k.recs[k.first(1, 'I')].len >= 5, "Input reported fewer bytes than were asked for");
        k.expect(k.count(1, 'D') == 0, "Data was delivered before the library released the bytes");
        k.expect(io.peek(k.link[1]) == "abcdefg", "peek did not show the unread bytes");
        k.expect(io.peek(k.link[1]) == "abcdefg", "peek consumed bytes");
        io.wait_input(k.link[1], 0);
        k.step = 4;
    } else if k.step == 4 && k.received(1).len >= 7 {
        k.expect(k.received(1) == "abcdefg", "the bytes delivered after wait_input(0) were not the ones peeked");
        k.expect(k.count(1, 'I') == 1, "more than one Input was delivered for one wait");
        io.close(k.link[0]);
        k.finish();
    }
}

fn c_wait_input_peer_ends<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.wait_input(k.link[1], 100);
        io.send(k.link[0], pattern(10)[..]);
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'I') >= 0 {
        k.expect(k.recs[k.first(1, 'I')].len == 10, "Input after the peer ended did not report the 10 bytes that came");
        k.expect(io.peek(k.link[1]) == pattern(10)[..], "peek did not show the bytes that came before the peer ended");
        io.wait_input(k.link[1], 0);
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'C') >= 0 {
        k.expect(k.received(1) == pattern(10)[..], "the bytes were not delivered before the link closed");
        k.expect(k.closed_with(1, goose_io::CloseReason.PeerClosed), "the link did not end with PeerClosed");
        k.finish();
    }
}

fn c_peek_bound<Io>(k: Case&, io: Io&, fx: Fixture, ev: goose_io::Event) {
    if fx.peek_bound <= 0 { k.finish(); return; }
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.n = fx.peek_bound * 2;
        io.wait_input(k.link[1], k.n);
        io.send(k.link[0], pattern(k.n)[..]);
        k.t = io.now_ms();
        io.tick_by(k.t + 200);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'I') >= 0 && io.now_ms() >= k.t + 200 {
        k.expect(k.recs[k.first(1, 'I')].len == fx.peek_bound, "Input at the bound did not report the bound as available");
        k.expect(io.peek(k.link[1]).len == fx.peek_bound, "peek at the bound did not show exactly the bound");
        k.expect(k.count(1, 'I') == 1 && k.count(1, 'D') == 0, "reading did not stop at the bound");
        io.wait_input(k.link[1], 0);
        k.step = 3;
    } else if k.step == 3 && k.received(1).len >= k.n {
        k.expect(k.received(1) == pattern(k.n)[..], "the bytes were not all delivered after the bound was lifted");
        io.close(k.link[0]);
        k.finish();
    }
}

fn c_discard_input_drops<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.wait_input(k.link[1], 7);
        io.send(k.link[0], "abcdefg");
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'I') >= 0 {
        k.expect(io.discard_input(k.link[1], 3) == 3, "discard_input did not report the 3 bytes dropped");
        k.expect(io.peek(k.link[1]) == "defg", "the bytes after the dropped ones were not left held");
        k.expect(io.discard_input(k.link[1], 100) == 4, "discard_input dropped more than was held");
        k.expect(io.peek(k.link[1]).len == 0, "bytes were still held after all were dropped");
        io.wait_input(k.link[1], 0);
        io.send(k.link[0], "xy");
        k.step = 3;
    } else if k.step == 3 && k.received(1).len >= 2 {
        k.expect(k.received(1) == "xy", "dropped bytes were delivered");
        k.expect(k.count(1, 'I') == 1, "discard_input delivered an Input");
        io.close(k.link[0]);
        k.finish();
    }
}

fn peek_capability_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 620 { c_wait_input_gathers(k, io, ev); return true; }
    if k.id == 621 { c_wait_input_peer_ends(k, io, ev); return true; }
    if k.id == 622 { c_peek_bound(k, io, fx, ev); return true; }
    if k.id == 623 { c_discard_input_drops(k, io, ev); return true; }
    return false;
}
