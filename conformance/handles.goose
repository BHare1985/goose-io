// goose-io conformance suite, group 4.3: handles, delivery, event order and ownership.
// Requirements: Links are generation-checked handles; Events are delivered to one handler, one at a time;
// Link events follow a fixed order; Every link event names its owner.
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
    if id == 106 { return Info { name: "owner_tags", req: "Every link event names its owner", part: 0 }; }
    if id == 107 { return Info { name: "owner_user_value", req: "Every link event names its owner", part: 0 }; }
    if id == 109 { return Info { name: "handles_stale_reset", req: "Links are generation-checked handles", part: 0 }; }
    if id == 110 { return Info { name: "handles_stale_send_room", req: "Links are generation-checked handles", part: 0 }; }
    if id == 111 { return Info { name: "handles_stale_user", req: "Links are generation-checked handles", part: 0 }; }
    if id == 112 { return Info { name: "handles_unset_reset", req: "Links are generation-checked handles", part: 0 }; }
    if id == 113 { return Info { name: "handles_unset_shutdown_write", req: "Links are generation-checked handles", part: 0 }; }
    if id == 114 { return Info { name: "handles_unset_sizing", req: "Links are generation-checked handles", part: 0 }; }
    if id == 115 { return Info { name: "handles_unset_inspection", req: "Links are generation-checked handles", part: 0 }; }
    if id == 116 { return Info { name: "events_not_reentrant_after_reset", req: "Events are delivered to one handler, one at a time", part: 0 }; }
    if id == 108 { return Info { name: "owner_user_after_failed_dial", req: "Every link event names its owner", part: 0 }; }
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
// user value it was given, so that nothing the stale handle did reached them.
fn stale_finish<Io>(k: Case&, io: Io&) {
    if k.step == 4 && k.received(3).len >= 5 && k.received(2).len >= 5 {
        k.expect(k.received(3) == "fresh" && k.received(2) == "fresh", "a new link received something other than what its peer sent");
        k.expect(k.is_open(2) && k.is_open(3), "a stale handle closed or reset a new link");
        k.expect(k.recs[k.first(2, 'D')].user == 5 && k.recs[k.first(3, 'D')].user == 6, "a stale handle changed the user value of a new link");
        io.close(k.link[2]);
        k.step = 5;
        k.finish();
    }
}

// A stale handle cannot reach a reused slot: set_user, pause_reading, close and send with it touch no new link.
fn c_handles_stale_reuse<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        let fresh = k.link[2];
        io.set_user(fresh, 5);
        io.set_user(k.link[3], 6);
        io.set_user(k.old, 99);
        io.pause_reading(k.old, true);
        io.close(k.old);
        k.expect(io.send(k.old, "stale") == goose_io::SendStatus.Closed, "send with a stale handle did not return Closed");
        io.send(fresh, "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The abort group: reset with a stale handle resets no new link.
fn c_handles_stale_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        io.set_user(k.link[2], 5);
        io.set_user(k.link[3], 6);
        io.reset(k.old);
        io.send(k.link[2], "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The sizing group: send_room and send2 with a stale handle report no room and a closed link.
fn c_handles_stale_send_room<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        io.set_user(k.link[2], 5);
        io.set_user(k.link[3], 6);
        k.expect(io.send_room(k.old) == 0, "send_room with a stale handle was not 0");
        k.expect(io.send2(k.old, "a", "b") == goose_io::SendStatus.Closed, "send2 with a stale handle did not return Closed");
        io.send(k.link[2], "fresh");
        io.send(k.link[3], "fresh");
        k.step = 4;
    }
    stale_finish(k, io);
}

// The inspection group: user and peer_address with a stale handle answer 0 and an empty value, and do not answer
// for the new link.
fn c_handles_stale_user<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if stale_ready(k, io) {
        io.set_user(k.link[2], 5);
        io.set_user(k.link[3], 6);
        k.expect(io.user(k.old) == 0, "user with a stale handle was not 0");
        k.expect(goose_io::is_empty(io.peer_address(k.old)), "peer_address with a stale handle was not empty");
        k.expect(io.user(k.link[2]) == 5, "set_user on a new link did not stay");
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
// handle was used for changed it. `user0` is the user value the first link was given.
fn unset_finish<Io>(k: Case&, io: Io&, user0: u32) {
    if k.step == 2 && k.received(0).len >= 9 && k.received(1).len >= 9 {
        k.expect(k.is_open(0) && k.is_open(1), "an operation with an unset handle closed or reset a link");
        k.expect(k.recs[k.first(0, 'D')].user == user0 && k.recs[k.first(1, 'D')].user == 0, "an operation with an unset handle changed a user value");
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
        io.set_user(none, 5);
        k.expect(io.send(none, "x") == goose_io::SendStatus.Closed, "send on an unset Link did not return Closed");
        unset_traffic(k, io);
    }
    unset_finish(k, io, 0);
}

// The abort group.
fn c_handles_unset_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        io.reset(goose_io::Link { .. });
        unset_traffic(k, io);
    }
    unset_finish(k, io, 0);
}

// The half-close group: shutdown_write with an unset handle shuts no link.
fn c_handles_unset_shutdown_write<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        io.shutdown_write(goose_io::Link { .. });
        unset_traffic(k, io);
    }
    unset_finish(k, io, 0);
}

// The sizing group.
fn c_handles_unset_sizing<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        let none = goose_io::Link { .. };
        k.expect(io.send_room(none) == 0, "send_room of an unset Link was not 0");
        k.expect(io.send2(none, "x", "y") == goose_io::SendStatus.Closed, "send2 on an unset Link did not return Closed");
        unset_traffic(k, io);
    }
    unset_finish(k, io, 0);
}

// The inspection group: user and peer_address of an unset handle answer 0 and an empty value, whatever a link has.
fn c_handles_unset_inspection<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if unset_ready(k, io) {
        io.set_user(k.link[0], 7);
        let none = goose_io::Link { .. };
        k.expect(io.user(none) == 0, "user of an unset Link was not 0");
        k.expect(goose_io::is_empty(io.peer_address(none)), "peer_address of an unset Link was not empty");
        unset_traffic(k, io);
    }
    unset_finish(k, io, 7);
}

// --- 102: the handle is valid while Closed is handled, and stale after ----------------------------

fn c_handles_valid_in_closed<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.set_user(k.link[0], 42);
        k.expect(!goose_io::is_empty(io.peer_address(k.link[0])), "peer_address of an open link was empty");
        k.old = k.link[0];
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 {
        match ev {
            Closed e => {
                if goose_io::same(e.link, k.old) {
                    k.expect(io.user(e.link) == 42, "user was not available while Closed was handled");
                    k.expect(e.user == 42, "the Closed event did not carry the user value");
                    k.step = 3;
                }
            },
            _ => {},
        }
    } else if k.step == 3 {
        // the handler has returned: the handle is stale
        k.expect(io.user(k.old) == 0, "user of a link after its Closed was not 0");
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

// The abort group: a send on a link whose peer has just reset returns before the Closed that follows.
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

// --- 106: events carry the tag; two pairs with different tags share the loop ----------------------

fn c_owner_tags<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
        io.send(k.link[1], "to the first client");
        io.send(k.link[3], "to the second client");
        k.step = 2;
    } else if k.step == 2 && k.received(0).len >= 19 && k.received(2).len >= 20 {
        // track already failed the check if any event carried a tag that is not its link's
        k.expect(k.received(0) == "to the first client" && k.received(2) == "to the second client", "bytes arrived on the wrong link");
        io.close(k.link[0]);
        io.close(k.link[2]);
        k.finish();
    }
}

// --- 107: the user value comes back --------------------------------------------------------------

fn c_owner_user_value<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.set_user(k.link[0], 41);
        io.set_user(k.link[1], 17);
        io.send(k.link[1], "x");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'D') >= 0 {
        k.expect(k.recs[k.first(0, 'D')].user == 41, "Data did not carry the user value set with set_user");
        io.send(k.link[0], "y");
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'D') >= 0 {
        k.expect(k.recs[k.first(1, 'D')].user == 17, "Data on the accepted link did not carry its user value");
        io.close(k.link[0]);
        k.step = 4;
    } else if k.step == 4 && k.first(0, 'C') >= 0 {
        k.expect(k.recs[k.first(0, 'C')].user == 41, "Closed did not carry the user value");
        k.finish();
    }
}

// --- 108: the user value survives an immediate dial failure ---------------------------------------

fn c_owner_user_after_failed_dial<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let link = k.dial_to(io, "not an address", 0, 0);
        io.set_user(link, 7);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.recs[k.first(0, 'C')].user == 7, "the Closed of a dial that failed at once did not carry the user value set after dial");
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
    if k.id == 106 { c_owner_tags(k, io, ev); return true; }
    if k.id == 107 { c_owner_user_value(k, io, ev); return true; }
    if k.id == 108 { c_owner_user_after_failed_dial(k, io, ev); return true; }
    return false;
}

// Runs the checks of the sizing group: true if the check is one of them.
fn handles_sizing_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 110 { c_handles_stale_send_room(k, io, ev); return true; }
    if k.id == 114 { c_handles_unset_sizing(k, io, ev); return true; }
    return false;
}

// Runs the checks of the half-close group: true if the check is one of them.
fn handles_half_close_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 113 { c_handles_unset_shutdown_write(k, io, ev); return true; }
    return false;
}

// Runs the checks of the abort group: true if the check is one of them.
fn handles_abort_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 109 { c_handles_stale_reset(k, io, ev); return true; }
    if k.id == 112 { c_handles_unset_reset(k, io, ev); return true; }
    if k.id == 116 { c_events_not_reentrant_after_reset(k, io, ev); return true; }
    return false;
}

// Runs the checks of the inspection group: true if the check is one of them.
fn handles_inspection_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 102 { c_handles_valid_in_closed(k, io, ev); return true; }
    if k.id == 111 { c_handles_stale_user(k, io, ev); return true; }
    if k.id == 115 { c_handles_unset_inspection(k, io, ev); return true; }
    return false;
}
