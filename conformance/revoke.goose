// goose-io conformance suite, revoke group: `discard_unsent` and `write_deadline`.
// Requirements: Revoke takes back unsent bytes; A write deadline stops writes at a time.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.data;

fn revoke_info(id: i64) -> Info {
    if id == 640 { return Info { name: "discard_unsent_drops", req: "Revoke takes back unsent bytes", part: 0 }; }
    if id == 641 { return Info { name: "write_deadline_stops", req: "A write deadline stops writes at a time", part: 0 }; }
    if id == 642 { return Info { name: "write_deadline_moved", req: "A write deadline stops writes at a time", part: 0 }; }
    return Info { .. };
}

fn c_discard_unsent_drops<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.n = fill(io, k.link[0], 64 << 20);
        k.expect(k.n > 0, "nothing was accepted before the first Full");
        k.q = io.discard_unsent(k.link[0]);
        k.expect(k.q >= 0 && k.q <= k.n, "discard_unsent returned a count outside what was sent");
        k.expect(io.send(k.link[0], pattern(1000)[..]) == goose_io::SendStatus.Sent, "a send after discard_unsent was not accepted");
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= k.n - k.q + 1000 {
        k.t = io.now_ms();
        io.tick_by(k.t + 200);
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 200 {
        k.expect(k.received(1).len == k.n - k.q + 1000, "the bytes that arrived were not the ones kept plus the later send");
        io.close(k.link[0]);
        k.finish();
    }
}

fn c_write_deadline_stops<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        fill(io, k.link[0], 64 << 20);
        k.t = io.now_ms();
        io.write_deadline(k.link[0], k.t + 500);
        io.tick_by(k.t + 500);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 {
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "the link did not end with Local at the deadline");
        k.expect(k.recs[k.first(0, 'C')].at >= k.t + 500, "the link closed before the deadline");
        k.expect(io.send(k.link[0], "x") == goose_io::SendStatus.Closed, "a send after the deadline was not refused with Closed");
        io.pause_reading(k.link[1], false);
        k.finish();
    }
}

fn c_write_deadline_moved<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        fill(io, k.link[0], 64 << 20);
        k.t = io.now_ms();
        io.write_deadline(k.link[0], k.t + 300);
        io.write_deadline(k.link[0], k.t + 3000);
        io.tick_by(k.t + 1000);
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 1000 {
        k.expect(k.first(0, 'C') < 0, "the link closed at a deadline that had been moved later");
        io.write_deadline(k.link[0], 0);
        io.tick_by(k.t + 2500);
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 4000 {
        k.expect(k.first(0, 'C') < 0, "the link closed at a deadline that had been removed");
        k.step = 4;
        io.pause_reading(k.link[1], false);
        io.close(k.link[0]);
        k.finish();
    } else if k.step == 3 {
        io.tick_by(k.t + 4000);
    }
}

fn revoke_group_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 640 { c_discard_unsent_drops(k, io, ev); return true; }
    if k.id == 641 { c_write_deadline_stops(k, io, ev); return true; }
    if k.id == 642 { c_write_deadline_moved(k, io, ev); return true; }
    return false;
}
