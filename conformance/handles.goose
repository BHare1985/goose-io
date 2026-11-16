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
    if id == 108 { return Info { name: "owner_user_after_failed_dial", req: "Every link event names its owner", part: 0 }; }
    return Info { .. };
}

// --- 100: a stale handle cannot reach a reused slot ----------------------------------------------

fn c_handles_stale_reuse<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.old = k.link[0];
        io.close(k.old);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        // the first link has had its Closed: its handle is stale. Make new links, which reuse its slot.
        k.connect_local(io, 1);
        k.step = 3;
    } else if k.step == 3 && k.pair_open(1) {
        let fresh = k.link[2];
        io.set_user(k.old, 99);
        io.pause_reading(k.old, true);
        io.close(k.old);
        io.reset(k.old);
        k.expect(io.send(k.old, "stale") == goose_io::SendStatus.Closed, "send with a stale handle did not return Closed");
        k.expect(io.send_room(k.old) == 0, "send_room with a stale handle was not 0");
        k.expect(io.user(k.old) == 0, "user with a stale handle was not 0");
        k.expect(io.user(fresh) == 0, "set_user with a stale handle changed a new link");
        k.expect(io.send(fresh, "fresh") == goose_io::SendStatus.Sent, "a new link could not send after a stale handle was used");
        k.step = 4;
    } else if k.step == 4 && k.received(3).len >= 5 {
        k.expect(k.received(3) == "fresh", "the new link received something other than what it sent");
        k.expect(k.is_open(2) && k.is_open(3), "a stale handle closed or reset a new link");
        k.expect(k.count(3, 'D') >= 1, "the new link was paused by a stale handle");
        io.close(k.link[2]);
        k.step = 5;
        k.finish();
    }
}

// --- 101: an unset handle -----------------------------------------------------------------------

fn c_handles_unset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let none = goose_io::Link { .. };
        k.expect(!goose_io::is_valid(none), "a default Link was valid");
        io.close(none);
        io.reset(none);
        io.shutdown_write(none);
        io.pause_reading(none, true);
        io.set_user(none, 5);
        k.expect(io.send(none, "x") == goose_io::SendStatus.Closed, "send on an unset Link did not return Closed");
        k.expect(io.send2(none, "x", "y") == goose_io::SendStatus.Closed, "send2 on an unset Link did not return Closed");
        k.expect(io.send_room(none) == 0, "send_room of an unset Link was not 0");
        k.expect(io.user(none) == 0, "user of an unset Link was not 0");
        k.expect(goose_io::is_empty(io.peer_address(none)), "peer_address of an unset Link was not empty");
        k.step = 1;
        k.finish();
    }
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

fn c_events_not_reentrant<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.connect_local(io, 1);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
        // close: its Closed arrives later, as a separate delivery
        k.flag = false;
        io.close(k.link[0]);
        k.flag = true;
        // a send on a link whose peer has just reset returns before the Closed that follows
        k.n = 0;
        io.reset(k.link[3]);
        io.send(k.link[2], "after reset");
        k.n = 1;
        k.step = 2;
    } else if k.step >= 2 {
        match ev {
            Closed e => {
                k.expect(k.flag, "Closed was delivered from inside close");
                k.expect(k.n == 1, "Closed was delivered from inside a reset or a send");
            },
            _ => {},
        }
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 { k.finish(); }
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
        k.step = 3;
        k.finish();
    }
}

// --- 105: a dial that fails gives Closed and never Opened ------------------------------------------

fn c_order_failed_dial<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        // a malformed address, and an address that has a listener no longer
        k.dial_to(io, "not an address", 0, 0);
        if k.listen_local(io, 1) {
            io.stop_listening(k.l2);
            k.dial_local(io, 1, 0);
        }
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
    if k.id == 104 { c_order_accepted_link(k, io, ev); return true; }
    if k.id == 106 { c_owner_tags(k, io, ev); return true; }
    if k.id == 107 { c_owner_user_value(k, io, ev); return true; }
    if k.id == 108 { c_owner_user_after_failed_dial(k, io, ev); return true; }
    return false;
}

// Runs the checks not yet assigned to a group (tasks 4.2 to 4.4): true if the check is one of them.
fn handles_rest_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 100 { c_handles_stale_reuse(k, io, ev); return true; }
    if k.id == 101 { c_handles_unset(k, io, ev); return true; }
    if k.id == 102 { c_handles_valid_in_closed(k, io, ev); return true; }
    if k.id == 103 { c_events_not_reentrant(k, io, ev); return true; }
    if k.id == 105 { c_order_failed_dial(k, io, ev); return true; }
    return false;
}
