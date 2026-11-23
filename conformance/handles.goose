// goose-io conformance suite, capability 4.3: handles, delivery, event order and ownership.
// Requirements: Links are generation-checked handles; Events are delivered to one handler, one at a time;
// Link events follow a fixed order; A slot and generation pair is never issued twice; A slot is held until its Closed is
// is delivered; The invalid link is reserved; A link event is recognised by what the library holds; Slot numbers are dense;
// A slot is freed when its Closed has been handled; Dialling never blocks and always ends in one event.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn handles_info(id: i64) -> Info {
    if id == 100 { return Info { name: "handles_stale_reuse", req: "Links are generation-checked handles", part: 0 }; }
    if id == 101 { return Info { name: "handles_unset", req: "Links are generation-checked handles", part: 0 }; }
    if id == 102 { return Info { name: "handles_valid_in_closed", req: "Links are generation-checked handles", part: 0 }; }
    if id == 103 { return Info { name: "events_not_reentrant", req: "Events are delivered to one handler, one at a time", part: 0 }; }
    if id == 104 { return Info { name: "order_accepted_link", req: "Link events follow a fixed order", part: 0 }; }
    if id == 105 { return Info { name: "order_failed_dial", req: "Link events follow a fixed order", part: 0 }; }
    if id == 106 { return Info { name: "owner_listener_named", req: "A link event is recognised by what the library holds", part: 0 }; }
    if id == 107 { return Info { name: "owner_dial_found_by_link", req: "A link event is recognised by what the library holds", part: 0 }; }
    if id == 109 { return Info { name: "handles_stale_reset", req: "Links are generation-checked handles", part: 0 }; }
    if id == 110 { return Info { name: "handles_stale_send_room", req: "Links are generation-checked handles", part: 0 }; }
    if id == 111 { return Info { name: "handles_stale_peer_address", req: "Links are generation-checked handles", part: 0 }; }
    if id == 112 { return Info { name: "handles_unset_reset", req: "Links are generation-checked handles", part: 0 }; }
    if id == 113 { return Info { name: "handles_unset_shutdown_write", req: "Links are generation-checked handles", part: 0 }; }
    if id == 114 { return Info { name: "handles_unset_sizing", req: "Links are generation-checked handles", part: 0 }; }
    if id == 115 { return Info { name: "handles_unset_inspection", req: "Links are generation-checked handles", part: 0 }; }
    if id == 116 { return Info { name: "events_not_reentrant_after_reset", req: "Events are delivered to one handler, one at a time", part: 0 }; }
    if id == 108 { return Info { name: "slots_dense", req: "Slot numbers are dense", part: 0 }; }
    if id == 90 { return Info { name: "setup_before_serve", req: "A loop is set up, serving, draining or finished", part: 0 }; }
    if id == 119 { return Info { name: "handles_pair_unique", req: "A slot and generation pair is never issued twice", part: 0 }; }
    if id == 120 { return Info { name: "handles_slot_held", req: "A slot is held until its Closed is delivered", part: 0 }; }
    if id == 117 { return Info { name: "slot_kept_during_closed", req: "A slot is freed when its Closed has been handled", part: 0 }; }
    if id == 118 { return Info { name: "dial_no_event_inside", req: "Dialling never blocks and always ends in one event", part: 0 }; }
    return Info { .. };
}

// --- 100: a stale handle cannot reach a reused slot ----------------------------------------------

// The setup shared by the checks of a stale handle: a link is made and closed, and its handle `k.old` is stale once
// its Closed has been delivered; then a second pair is made, which reuses its slot. True at the event at which the
// second pair is open and the stale handle can be used (the check then moves `k.step` on).
fn stale_ready<Io>(k: Case&, io: Io&) -> bool {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.old = k.link[0];
        io.close(k.old);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.connect_local(io, 1);
        k.step = 3;
    } else if k.step == 3 && k.pair_open(1) {
        return true;
    }
    return false;
}

// What the checks of a stale handle see in the end: both new links open, and each carried its own message with the
// message it was sent, so that nothing the stale handle did reached them.
fn stale_finish<Io>(k: Case&, io: Io&) {
    if k.step == 4 && k.received(3).len >= 5 && k.received(2).len >= 5 {
        k.expect(k.received(3) == "fresh" && k.received(2) == "fresh", "a new link received something other than what its peer sent");
        k.expect(k.is_open(2) && k.is_open(3), "a stale handle closed or reset a new link");
        io.close(k.link[2]);
        k.step = 5;
        k.finish();
    }
}

// A stale handle cannot reach a reused slot: pause_reading, close and send with it touch no new link.
fn c_handles_stale_reuse<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        let fresh = k.link[2];
        io.pause_reading(k.old, true);
        io.close(k.old);
        k.expect(io.send(k.old, "stale") == goose_io::SendStatus.Closed, "send with a stale handle did not return Closed");
        io.send(fresh, "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The abort capability: reset with a stale handle resets no new link.
fn c_handles_stale_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        io.reset(k.old);
        io.send(k.link[2], "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The sizing capability: send_room and send2 with a stale handle report no room and a closed link.
fn c_handles_stale_send_room<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        k.expect(io.send_room(k.old) == 0, "send_room with a stale handle was not 0");
        k.expect(io.send2(k.old, "a", "b") == goose_io::SendStatus.Closed, "send2 with a stale handle did not return Closed");
        io.send(k.link[2], "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The inspection capability: peer_address with a stale handle answers an empty value, and does not answer for the new link.
fn c_handles_stale_peer_address<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        k.expect(goose_io::is_empty(io.peer_address(k.old)), "peer_address with a stale handle was not empty");
        k.expect(!goose_io::is_empty(io.peer_address(k.link[2])), "peer_address of the new link in the reused slot was empty");
        io.send(k.link[2], "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// --- 101: an unset handle -----------------------------------------------------------------------

// The setup shared by the checks of an unset handle: a pair of links is open at the first slots, so that an operation
// that took the unset handle for a slot would reach a real link. True at the event at which the pair is open.
fn unset_ready<Io>(k: Case&, io: Io&) -> bool {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        return true;
    }
    return false;
}

// What the checks of an unset handle see in the end: the pair still works in both directions, and nothing the unset
// handle was used for changed it.
fn unset_finish<Io>(k: Case&, io: Io&) {
    if k.step == 2 && k.received(0).len >= 9 && k.received(1).len >= 9 {
        k.expect(k.is_open(0) && k.is_open(1), "an operation with an unset handle closed or reset a link");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

fn unset_traffic<Io>(k: Case&, io: Io&) {
    k.expect(io.send(k.link[1], "to client") == goose_io::SendStatus.Sent, "a link could not send after an operation with an unset handle");
    k.expect(io.send(k.link[0], "to server") == goose_io::SendStatus.Sent, "a link could not send after an operation with an unset handle");
    k.step = 2;
}

// A default Link is invalid, and the operations of the core with it have no effect.
fn c_handles_unset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        let none = goose_io::Link { .. };
        k.expect(!goose_io::is_valid(none), "a default Link was valid");
        io.close(none);
        io.pause_reading(none, true);
        k.expect(io.send(none, "x") == goose_io::SendStatus.Closed, "send on an unset Link did not return Closed");
        unset_traffic(k, io);
    }
    unset_finish(k, io);
}

// The abort capability.
fn c_handles_unset_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        io.reset(goose_io::Link { .. });
        unset_traffic(k, io);
    }
    unset_finish(k, io);
}

// The half-close capability: shutdown_write with an unset handle shuts no link.
fn c_handles_unset_shutdown_write<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        io.shutdown_write(goose_io::Link { .. });
        unset_traffic(k, io);
    }
    unset_finish(k, io);
}

// The sizing capability.
fn c_handles_unset_sizing<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        let none = goose_io::Link { .. };
        k.expect(io.send_room(none) == 0, "send_room of an unset Link was not 0");
        k.expect(io.send2(none, "x", "y") == goose_io::SendStatus.Closed, "send2 on an unset Link did not return Closed");
        unset_traffic(k, io);
    }
    unset_finish(k, io);
}

// The inspection capability: peer_address of an unset handle answers an empty value, whatever a link has.
fn c_handles_unset_inspection<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        let none = goose_io::Link { .. };
        k.expect(goose_io::is_empty(io.peer_address(none)), "peer_address of an unset Link was not empty");
        unset_traffic(k, io);
    }
    unset_finish(k, io);
}

// --- 102: the handle is valid while Closed is handled, and stale after ----------------------------

fn c_handles_valid_in_closed<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(!goose_io::is_empty(io.peer_address(k.link[0])), "peer_address of an open link was empty");
        k.old = k.link[0];
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 {
        match ev {
            Closed e => {
                if goose_io::same(e.link, k.old) {
                    k.expect(!goose_io::is_empty(io.peer_address(e.link)), "peer_address was not available while Closed was handled");
                    k.step = 3;
                }
            },
            _ => {},
        }
    } else if k.step == 3 {
        // the handler has returned: the handle is stale
        k.expect(goose_io::is_empty(io.peer_address(k.old)), "peer_address of a link after its Closed was not empty");
        k.step = 4;
        k.finish();
    }
}

// --- 103: operations never deliver an event before they return ------------------------------------

// A close does not deliver its Closed before it returns.
fn c_events_not_reentrant<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        // close: its Closed arrives later, as a separate delivery
        k.flag = false;
        io.close(k.link[0]);
        k.flag = true;
        k.step = 2;
    } else if k.step >= 2 {
        match ev {
            Closed e => { k.expect(k.flag, "Closed was delivered from inside close"); },
            _ => {},
        }
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 { k.finish(); }
    }
}

// The abort capability: a send on a link whose peer has just reset returns before the Closed that follows.
fn c_events_not_reentrant_after_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.n = 0;
        io.reset(k.link[1]);
        io.send(k.link[0], "after reset");
        k.n = 1;
        k.step = 2;
    } else if k.step >= 2 {
        match ev {
            Closed e => { k.expect(k.n == 1, "Closed was delivered from inside a reset or a send"); },
            _ => {},
        }
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 { k.finish(); }
    }
}

// --- 104: an accepted link sees Opened, Data in order, Closed -------------------------------------

fn only_data(kinds: const u8[:]) -> bool {
    if kinds.len < 3 || kinds[0] != 'O' || kinds[kinds.len - 1] != 'C' { return false; }
    for i in kinds.len - 2 { if kinds[i + 1] != 'D' { return false; } }
    return true;
}

fn c_order_accepted_link<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "first message,");
        io.send(k.link[0], "second message");
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'C') >= 0 {
        k.expect(only_data(k.kinds(1)), "an accepted link did not see Opened, then Data, then Closed");
        k.expect(k.received(1) == "first message,second message", "the Data events did not carry the bytes in order");
        k.expect(k.count(1, 'O') == 1 && k.count(1, 'C') == 1, "an accepted link did not see exactly one Opened and one Closed");
        k.expect(k.closed_with(1, goose_io::CloseReason.PeerClosed), "the peer's end of stream did not close the link with PeerClosed");
        k.step = 3;
        k.finish();
    }
}

// --- 105: a dial that fails gives Closed and never Opened ------------------------------------------

fn c_order_failed_dial<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        // a malformed address, and an address that nothing listens on
        k.expect(fx.refused.len > 0, "the fixture supplied no address that nothing listens on");
        k.dial_to(io, "not an address", 0, 0);
        k.dial_to(io, fx.refused, 1, 0);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 && k.first(2, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a dial to a malformed address did not give exactly one Closed and no Opened");
        k.expect(k.kinds(2) == "C", "a refused dial did not give exactly one Closed and no Opened");
        k.step = 2;
        k.finish();
    }
}

// --- 106: an accepted link names its own listener -------------------------------------------------

fn c_owner_listener_named<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        // two listeners, and a dial to each: the second pair first
        k.listen_local(io, 0);
        let first_port = k.port;
        k.listen_local(io, 1);
        k.dial_to(io, local_text(k.port)[..], 1, 0);
        k.dial_to(io, local_text(first_port)[..], 0, 0);
        k.expect(!goose_io::same(k.l, k.l2), "two listeners were given the same handle");
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
        k.expect(goose_io::same(k.recs[k.first(1, 'O')].listener, k.l), "the accepted link of the first listener did not name it");
        k.expect(goose_io::same(k.recs[k.first(3, 'O')].listener, k.l2), "the accepted link of the second listener did not name it");
        io.send(k.link[1], "to the first client");
        io.send(k.link[3], "to the second client");
        k.step = 2;
    } else if k.step == 2 && k.received(0).len >= 19 && k.received(2).len >= 20 {
        k.expect(k.received(0) == "to the first client" && k.received(2) == "to the second client", "bytes arrived on the wrong link");
        io.close(k.link[0]);
        io.close(k.link[2]);
        k.finish();
    }
}

// --- 107: a dial that fails at once is found by the link dial returned ------------------------------

fn c_owner_dial_found_by_link<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.dial_to(io, "not an address", 0, 0);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a dial that failed at once did not give exactly one Closed");
        k.finish();
    }
}

// --- 108: slots are dense -------------------------------------------------------------------------

// The slots of every link of a check are below 4: no check holds more than two pairs of links at once, so a loop that
// reuses a freed slot before it issues a new one never goes above that.
fn c_slots_dense<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
        for r in 4 { k.prev[r] = k.link[r]; k.expect(k.link[r].slot < 4, "a link of the first round had a slot of 4 or more"); io.close(k.link[r]); }
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
        // a second round once every Closed has been handled: their slots are free
        k.recs.clear();
        k.live = 0;
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.step = 3;
    } else if k.step == 3 && k.pair_open(0) && k.pair_open(1) {
        for r in 4 {
            k.expect(k.link[r].slot < 4, "a slot freed by a closed link was not used before a new one: a link of the second round had a slot of 4 or more");
            for p in 4 {
                if k.link[r].slot == k.prev[p].slot { k.expect(k.link[r].gen != k.prev[p].gen, "a reused slot had the same generation"); }
            }
            io.close(k.link[r]);
        }
        k.step = 4;
        k.finish();
    }
}

// --- 117: a slot is not freed until the handlers of its Closed have returned --------------------------

fn c_slot_kept_during_closed<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.old = k.link[0];
        io.close(k.old);
        k.step = 2;
    } else if k.step == 2 {
        match ev {
            Closed e => {
                if goose_io::same(e.link, k.old) {
                    // a link made inside the handler of the Closed does not take the slot of the link being closed
                    let fresh = io.dial("not an address", 0);
                    k.issued(fresh);
                    k.expect(fresh.slot != e.link.slot, "a link made inside a Closed handler took the slot of the link being closed");
                    k.link[2] = fresh;
                    k.live++;
                    k.step = 3;
                }
            },
            _ => {},
        }
    } else if k.step == 3 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 {
        k.finish();
    }
}

// --- 118: dial does not deliver an event before it returns -----------------------------------------

fn c_dial_no_event_inside<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.flag = false;
        k.dial_to(io, "not an address", 0, 0);       // fails at once
        k.flag = true;
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Closed e => { k.expect(k.flag, "Closed of a failed dial was delivered from inside dial"); },
            _ => {},
        }
        if k.first(0, 'C') >= 0 { k.finish(); }
    }
}

// --- 119: a slot and generation pair is never issued twice ---------------------------------------------------------

// Opens and closes a pair of links five times in a row, so that slots are reused. The driver records every handle it
// is given (`k.issued`, `k.sight`): this check fails when any pair was issued twice or a link had generation 0, in this
// part or earlier in it, and also that every link issued is valid.
fn c_handles_pair_unique<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(goose_io::is_valid(k.link[0]) && goose_io::is_valid(k.link[1]), "a link the loop issued was not valid");
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.n++;
        if k.n < 5 {
            k.recs.clear();
            k.live = 0;
            k.connect_local(io, 0);
            k.step = 1;
        } else {
            k.expect(!k.pair_bad, k.pair_why[..]);
            k.finish();
        }
    }
}

// --- 120: a slot is held until its Closed is delivered -------------------------------------------------------------

// A library closes a link and dials in the same handler: the new link is not in the closed link's slot.
fn c_handles_slot_held<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let closing = k.link[0];
        io.close(closing);
        let fresh = k.dial_to(io, "not an address", 1, 0);
        k.expect(fresh.slot != closing.slot, "a link dialled right after close was issued in the slot of the link still closing");
        k.expect(!k.slot_bad, k.slot_why[..]);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 {
        k.finish();
    }
}

// --- 90: what the entry point sets up before serve is delivered by serve ---------------------------------------------------

// Called by the driver before serve (part 0 of the core): listens and dials, and keeps the handles for the check below.
fn setup_before_serve_hook<Io>(k: Case&, io: Io&) {
    let l, err = io.listen("127.0.0.1:0");
    if !goose_io::is_listener(l) { return; }
    var text: u8[>..] = [];
    format(text, "127.0.0.1:", io.listener_port(l));
    let link = io.dial(text[..], 0);
    k.issued(link);
    k.pre_l = l;
    k.pre_link = link;
    k.pre_done = true;
}

// The check runs first in part 0: the links made before serve open, both ends, and the events arrive from serve.
fn c_setup_before_serve<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(k.pre_done && goose_io::is_listener(k.pre_l) && goose_io::is_valid(k.pre_link), "the entry point could not listen and dial before serve");
        k.l = k.pre_l;
        k.link[0] = k.pre_link;
        k.live = 1;
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.close(k.link[0]);
        k.finish();
    }
}

// Runs the checks of the core: true if the check is one of them.
fn handles_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 100 { c_handles_stale_reuse(k, io, ev); return true; }
    if k.id == 101 { c_handles_unset(k, io, ev); return true; }
    if k.id == 103 { c_events_not_reentrant(k, io, ev); return true; }
    if k.id == 104 { c_order_accepted_link(k, io, ev); return true; }
    if k.id == 105 { c_order_failed_dial(k, fx, io, ev); return true; }
    if k.id == 106 { c_owner_listener_named(k, io, ev); return true; }
    if k.id == 107 { c_owner_dial_found_by_link(k, io, ev); return true; }
    if k.id == 108 { c_slots_dense(k, io, ev); return true; }
    if k.id == 117 { c_slot_kept_during_closed(k, io, ev); return true; }
    if k.id == 90 { c_setup_before_serve(k, io, ev); return true; }
    if k.id == 119 { c_handles_pair_unique(k, io, ev); return true; }
    if k.id == 120 { c_handles_slot_held(k, io, ev); return true; }
    if k.id == 118 { c_dial_no_event_inside(k, io, ev); return true; }
    return false;
}

// Runs the checks of the sizing capability: true if the check is one of them.
fn handles_sizing_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 110 { c_handles_stale_send_room(k, io, ev); return true; }
    if k.id == 114 { c_handles_unset_sizing(k, io, ev); return true; }
    return false;
}

// Runs the checks of the half-close capability: true if the check is one of them.
fn handles_half_close_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 113 { c_handles_unset_shutdown_write(k, io, ev); return true; }
    return false;
}

// Runs the checks of the abort capability: true if the check is one of them.
fn handles_abort_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 109 { c_handles_stale_reset(k, io, ev); return true; }
    if k.id == 112 { c_handles_unset_reset(k, io, ev); return true; }
    if k.id == 116 { c_events_not_reentrant_after_reset(k, io, ev); return true; }
    return false;
}

// Runs the checks of the inspection capability: true if the check is one of them.
fn handles_inspection_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 102 { c_handles_valid_in_closed(k, io, ev); return true; }
    if k.id == 111 { c_handles_stale_peer_address(k, io, ev); return true; }
    if k.id == 115 { c_handles_unset_inspection(k, io, ev); return true; }
    return false;
}
