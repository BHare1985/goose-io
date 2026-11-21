// goose-io conformance suite, relay group: `relay` and `relayed_bytes`.
// Requirements: Relay joins two links inside the loop; A relay holds back and ends as a pair; A relayed link is owned by the relay.
// The checks use two pairs: roles 0 and 2 are the clients, roles 1 and 3 are the links the loop relays.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.data;

fn relay_info(id: i64) -> Info {
    if id == 600 { return Info { name: "relay_carries_bytes", req: "Relay joins two links inside the loop", part: 0 }; }
    if id == 601 { return Info { name: "relay_refusals", req: "Relay joins two links inside the loop", part: 0 }; }
    if id == 602 { return Info { name: "relay_holds_back_unread", req: "A relay holds back and ends as a pair", part: 0 }; }
    if id == 603 { return Info { name: "relay_send_refused_and_close_ends_both", req: "A relayed link is owned by the relay", part: 0 }; }
    return Info { .. };
}

fn two_pairs<Io>(k: Case&, io: Io&) {
    k.connect_local(io, 0);
    k.connect_local(io, 1);
}

fn both_open(k: Case&) -> bool { k.pair_open(0) && k.pair_open(1) }

fn c_relay_carries_bytes<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        two_pairs(k, io);
        k.step = 1;
    } else if k.step == 1 && both_open(k) {
        k.expect(io.relay(k.link[1], k.link[3]) == goose_io::RelayStatus.Started, "relay of two open links did not return Started");
        io.send(k.link[0], "hello");
        io.send(k.link[2], "world");
        k.step = 2;
    } else if k.step == 2 && k.received(2) == "hello" && k.received(0) == "world" {
        k.expect(k.count(1, 'D') == 0 && k.count(3, 'D') == 0, "the library was given bytes of a relayed link");
        k.expect(io.relayed_bytes(k.link[1]) == 5 && io.relayed_bytes(k.link[3]) == 5, "relayed_bytes was not the bytes carried from each link");
        k.step = 3;
        io.close(k.link[0]);
        io.close(k.link[2]);
        k.finish();
    }
}

fn c_relay_refusals<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.expect(io.relay(k.link[0], k.link[2]) == goose_io::RelayStatus.NotOpen, "relay of a dialling link did not return NotOpen");
        k.step = 1;
    } else if k.step == 1 && both_open(k) {
        k.expect(io.relay(k.link[1], goose_io::Link { .. }) == goose_io::RelayStatus.Closed, "relay with a stale link did not return Closed");
        k.expect(io.relay(k.link[1], k.link[3]) == goose_io::RelayStatus.Started, "relay of two open links did not return Started");
        k.expect(io.relay(k.link[1], k.link[3]) == goose_io::RelayStatus.AlreadyRelayed, "relay of joined links did not return AlreadyRelayed");
        k.expect(io.relay(k.link[0], k.link[1]) == goose_io::RelayStatus.AlreadyRelayed, "relay with a joined link did not return AlreadyRelayed");
        io.close(k.link[0]);
        k.expect(io.relay(k.link[0], k.link[2]) == goose_io::RelayStatus.Closed, "relay of a closing link did not return Closed");
        k.step = 2;
        k.finish();
    }
}

fn c_relay_holds_back_unread<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        two_pairs(k, io);
        k.step = 1;
    } else if k.step == 1 && both_open(k) {
        k.expect(io.relay(k.link[1], k.link[3]) == goose_io::RelayStatus.Started, "relay did not return Started");
        io.pause_reading(k.link[2], true);
        k.step = 2;
    } else if k.step == 2 || k.step == 4 {
        // keep sending until the loop refuses: the bytes of a peer that does not read must not be held without bound.
        // Twice: the first Full can come before the loop has moved the bytes on, and what it moved is held by the peer's side.
        var more = true;
        while more {
            let r = io.send(k.link[0], pattern(io.max_send())[..]);
            if r == goose_io::SendStatus.Sent { k.n += io.max_send(); } else { more = false; }
            if k.n > (64 << 20) { more = false; }
        }
        k.expect(k.n <= (64 << 20), "a relay to a peer that does not read accepted 64 MiB without a Full");
        k.t = io.now_ms();
        io.tick_by(k.t + 300);
        k.step += 1;
    } else if k.step == 3 && io.now_ms() >= k.t + 300 {
        k.step = 4;
    } else if k.step == 5 && io.now_ms() >= k.t + 300 {
        k.expect(k.n > 0, "nothing was accepted before the first Full");
        k.expect(io.relayed_bytes(k.link[1]) < k.n, "relayed_bytes counted bytes that were only held");
        io.pause_reading(k.link[2], false);
        k.step = 6;
    } else if k.step == 6 && k.received(2).len >= k.n {
        k.expect(k.received(2).len == k.n, "the relay delivered a different number of bytes than were sent");
        k.expect(io.relayed_bytes(k.link[1]) == k.n, "relayed_bytes was not the bytes sent once all had been carried");
        k.step = 7;
        io.close(k.link[0]);
        io.close(k.link[2]);
        k.finish();
    }
}

fn c_relay_send_refused_and_close_ends_both<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        two_pairs(k, io);
        k.step = 1;
    } else if k.step == 1 && both_open(k) {
        k.expect(io.relay(k.link[1], k.link[3]) == goose_io::RelayStatus.Started, "relay did not return Started");
        k.expect(io.send(k.link[1], "x") == goose_io::SendStatus.Closed, "a send on a relayed link was not refused with Closed");
        io.send(k.link[0], pattern(1000)[..]);
        k.step = 2;
    } else if k.step == 2 && k.received(2).len == 1000 {
        k.expect(io.relayed_bytes(k.link[1]) == 1000, "relayed_bytes of the sending side was not 1000");
        k.expect(io.relayed_bytes(k.link[3]) == 0, "relayed_bytes of the silent side was not 0");
        io.close(k.link[1]);
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'C') >= 0 && k.first(3, 'C') >= 0 {
        k.expect(k.closed_with(1, goose_io::CloseReason.Local), "the closed end did not end with Local");
        k.expect(k.closed_with(3, goose_io::CloseReason.Local), "the partner of a closed relay end did not end with Local");
        k.finish();
    }
}

fn relay_group_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 600 { c_relay_carries_bytes(k, io, ev); return true; }
    if k.id == 601 { c_relay_refusals(k, io, ev); return true; }
    if k.id == 602 { c_relay_holds_back_unread(k, io, ev); return true; }
    if k.id == 603 { c_relay_send_refused_and_close_ends_both(k, io, ev); return true; }
    return false;
}
