// goose-io conformance suite: link states and how operations complete (the change lifecycle-guarantees).
// Requirements: A link is in one of five states; Sending has one result in each link state; A Closed send result is
// final; Ending a link has one result in each link state; Pausing takes effect in every live state; Keep-open is
// configured no later than Opened; Each operation says how it completes.
//
// Each check of a group calls only the core and its own group's operations (tests/conformance/groups_check.sh).
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.data;

fn states_info(id: i64) -> Info {
    if id == 350 { return Info { name: "states_send", req: "Sending has one result in each link state", part: 0 }; }
    if id == 351 { return Info { name: "states_closed_is_final", req: "A Closed send result is final", part: 0 }; }
    if id == 352 { return Info { name: "states_close", req: "Ending a link has one result in each link state", part: 0 }; }
    if id == 353 { return Info { name: "states_pause", req: "Pausing takes effect in every live state", part: 0 }; }
    if id == 354 { return Info { name: "states_completion", req: "Each operation says how it completes", part: 0 }; }
    if id == 360 { return Info { name: "states_half_close", req: "Ending a link has one result in each link state", part: 0 }; }
    if id == 361 { return Info { name: "states_keep_open", req: "Keep-open is configured no later than Opened", part: 0 }; }
    if id == 362 { return Info { name: "states_sizing", req: "Sending has one result in each link state", part: 0 }; }
    if id == 363 { return Info { name: "states_reset", req: "Ending a link has one result in each link state", part: 0 }; }
    if id == 364 { return Info { name: "states_inspection", req: "A link reports its peer's address", part: 0 }; }
    if id == 355 { return Info { name: "states_closed_wakes_nothing", req: "A Closed send result is final", part: 0 }; }
    return Info { .. };
}

// --- 600: sending has one result in each link state --------------------------------------------------------------

// One link in each state (dialling, open, closing, ended), and a link the event loop ends while the library sees it open.
fn c_states_send<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.expect(io.send(k.link[0], "0123456789") == goose_io::SendStatus.NotOpen, "send on a dialling link did not return NotOpen");
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(io.send(k.link[0], "0123456789") == goose_io::SendStatus.Sent, "send on an open link did not return Sent");
        io.close(k.link[0]);
        k.expect(io.send(k.link[0], "0123456789") == goose_io::SendStatus.Closed, "send on a closing link did not return Closed");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(io.send(k.link[0], "0123456789") == goose_io::SendStatus.Closed, "send on an ended link did not return Closed");
        // the event loop ends a link that the library still sees as open: its peer closed
        k.connect_local(io, 1);
        k.step = 3;
    } else if k.step == 3 && k.pair_open(1) {
        io.close(k.link[3]);
        let r = io.send(k.link[2], "x");
        k.expect(r == goose_io::SendStatus.Sent || r == goose_io::SendStatus.Closed, "send on a link whose peer closed returned neither Sent nor Closed");
        k.step = 4;
    } else if k.step == 4 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
        k.expect(k.count(2, 'C') == 1, "the link the event loop ended did not receive exactly one Closed");
        k.finish();
    }
}

// --- 601: a Closed send result is final --------------------------------------------------------------------------

// Sends until the result is Closed, then checks that it stays so: the same value, and no Writable.
fn c_states_closed_is_final<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.close(k.link[1]);                    // the peer goes away
        k.n = 0;
        k.step = 2;
    } else if k.step == 2 {
        k.n++;
        let r = io.send(k.link[0], "x");
        k.expect(k.n < 500, "send never returned Closed on a link whose peer had closed");
        if r == goose_io::SendStatus.Closed {
            // at once, in the same handler: the link has not had its Closed delivered, so the handle is still current
            for i in 3 { k.expect(io.send(k.link[0], "x") == goose_io::SendStatus.Closed, "a send after a Closed result did not return Closed"); }
            k.step = 3;
        }
    } else if k.step == 3 {
        if k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
            k.expect(k.count(0, 'W') == 0, "a Writable was delivered for a link whose send had returned Closed");
            // a refused send, then a Closed result
            k.connect_local(io, 1);
            k.step = 4;
        }
    } else if k.step == 4 && k.pair_open(1) {
        io.pause_reading(k.link[3], true);
        k.expect(fill(io, k.link[2], 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.expect(io.send(k.link[2], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        io.close(k.link[3]);                    // the peer goes away while a send is refused
        k.n = 0;
        k.step = 5;
    } else if k.step == 5 {
        k.n++;
        let r = io.send(k.link[2], "x");
        k.expect(k.n < 500, "send never returned Closed on a refused link whose peer had closed");
        if r == goose_io::SendStatus.Closed {
            for i in 3 { k.expect(io.send(k.link[2], "x") == goose_io::SendStatus.Closed, "a send after a Closed result did not return Closed"); }
            k.step = 6;
        }
    } else if k.step == 6 {
        if k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
            k.expect(k.count(2, 'W') == 0, "a Writable was delivered for a refused link whose send then returned Closed");
            k.finish();
        }
    }
}

// --- 602: close twice ---------------------------------------------------------------------------------------------

fn c_states_close<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.close(k.link[0]);
        io.close(k.link[0]);                    // before its Closed is delivered
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.t = io.now_ms();
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 150 {
        k.expect(k.count(0, 'C') == 1, "a link closed twice did not receive exactly one Closed");
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "the Closed of a link closed twice did not have reason Local");
        k.finish();
    }
}

// --- 603: pause before Opened ---------------------------------------------------------------------------------

// A link paused while it is dialling delivers no Data until it is resumed, whatever its peer sends as soon as it opens.
fn c_states_pause<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        io.pause_reading(k.link[0], true);      // the dial has not opened yet
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[1], "ping");
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 100 {
        k.expect(k.count(0, 'D') == 0, "Data was delivered on a link paused before its Opened");
        io.pause_reading(k.link[0], false);
        k.step = 3;
    } else if k.step == 3 && k.received(0).len >= 4 {
        k.expect(k.received(0) == "ping", "the bytes held while paused did not arrive in order after the resume");
        io.close(k.link[0]);
        k.finish();
    }
}

// --- 604: how operations complete ---------------------------------------------------------------------------------

// Pausing is complete when it returns (no event reports it, and no Data comes while paused), and one Tick may answer
// several tick_by calls.
fn c_states_completion<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[1], "a");
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'D') >= 1 {
        // inside the handling of a Data event: pause, and let the peer go on sending
        io.pause_reading(k.link[0], true);
        io.send(k.link[1], "bcd");
        k.t = io.now_ms();
        k.m = k.recs.len;
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 100 {
        k.expect(k.count(0, 'D') == 1, "Data was delivered after pause_reading returned");
        k.expect(k.recs.len == k.m, "an event reported the pause or something else while the link was paused");
        io.pause_reading(k.link[0], false);
        k.step = 4;
    } else if k.step == 4 && k.received(0).len >= 4 {
        k.expect(k.received(0) == "abcd", "the bytes sent while the link was paused did not arrive in order");
        io.close(k.link[0]);
        k.step = 5;
    } else if k.step == 5 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.step = 6;
    } else if k.step == 6 {
        // wait for a Tick, then ask for two Ticks in one handler
        match ev {
            Tick t => { k.t = t.now_ms; io.tick_by(t.now_ms + 20); io.tick_by(t.now_ms + 50); k.step = 7; },
            _ => {},
        }
    } else if k.step == 7 {
        match ev {
            Tick t => {
                if t.now_ms >= k.t + 20 {
                    k.expect(t.now_ms < k.t + 100, "no Tick came at or soon after the earlier of two tick_by times");
                    k.finish();
                }
            },
            _ => {},
        }
    }
}

// A refused send, then a Closed result: nothing wakes the link (no Writable) before its Closed.
fn c_states_closed_wakes_nothing<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.expect(io.send(k.link[0], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        io.close(k.link[1]);
        k.n = 0;
        k.step = 2;
    } else if k.step == 2 {
        k.n++;
        k.expect(k.n < 500, "send never returned Closed on a refused link whose peer had closed");
        if io.send(k.link[0], "x") == goose_io::SendStatus.Closed { k.step = 3; }
    } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.count(0, 'W') == 0, "a Writable was delivered for a link whose send returned Closed");
        k.finish();
    }
}

// Runs the checks of the core: true if the check is one of them.
fn states_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 350 { c_states_send(k, io, ev); return true; }
    if k.id == 351 { c_states_closed_is_final(k, io, ev); return true; }
    if k.id == 352 { c_states_close(k, io, ev); return true; }
    if k.id == 353 { c_states_pause(k, io, ev); return true; }
    if k.id == 354 { c_states_completion(k, io, ev); return true; }
    if k.id == 355 { c_states_closed_wakes_nothing(k, io, ev); return true; }
    return false;
}

// --- the half-close group -------------------------------------------------------------------------------------------

// 360: sending on a write-shut link, shutdown before the link opens, close after shutdown, and what a Closed send result
// after shutdown means (only that sending has ended).
fn c_states_half_close<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    k.keep_open_on_accept(io, ev, 0);           // the peer of the shut end keeps its own end open, in its Opened handler
    k.keep_open_on_accept(io, ev, 1);
    if k.step == 0 {
        k.connect_local(io, 0);
        io.shutdown_write(k.link[0]);           // while it is dialling: no effect
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(io.send(k.link[0], "x") == goose_io::SendStatus.Sent, "a send after Opened did not return Sent although shutdown_write was called while dialling");
        k.m = k.recs.len;
        io.shutdown_write(k.link[0]);
        k.expect(io.send(k.link[0], "x") == goose_io::SendStatus.Closed, "a send right after shutdown_write did not return Closed");
        // the peer finishes after sending more: those bytes still arrive, with no Writable, and Closed only after it finished
        io.send(k.link[1], "late");
        k.step = 2;
    } else if k.step == 2 && k.received(0).len >= 4 {
        k.expect(k.received(0) == "late", "bytes sent by the peer after shutdown_write did not arrive");
        io.shutdown_write(k.link[1]);
        k.step = 3;
    } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.count(0, 'W') == 0, "a Writable was delivered for a write-shut link");
        for i in k.recs.len - k.m {
            let e = k.recs[k.m + i];
            if e.role == 0 { k.expect(e.kind == 'D' || e.kind == 'C', "an event other than Data and Closed was delivered for a write-shut link"); }
        }
        // close after shutdown: no further Data or PeerEof, one Closed with reason Local
        k.recs.clear();
        k.live = 0;
        k.connect_local(io, 1);
        k.step = 4;
    } else if k.step == 4 && k.pair_open(1) {
        io.shutdown_write(k.link[2]);
        io.close(k.link[2]);
        io.send(k.link[3], "more");
        io.shutdown_write(k.link[3]);
        k.step = 5;
    } else if k.step == 5 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
        k.expect(k.kinds(2) == "OC", "a link closed after shutdown_write received Data or PeerEof, or other than one Closed");
        k.expect(k.closed_with(2, goose_io::CloseReason.Local), "a link closed after shutdown_write did not close with reason Local");
        k.finish();
    }
}

// 361: keep-open is configured while dialling or in the handler of the link's Opened, and not later.
fn c_states_keep_open<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    // phases: 1 to 3 while dialling (pair 0) and in the accepted end's Opened handler (pair 1); 10 to 13 a late call; 20 to 23 an
    // end of stream that arrives before the dialled end's Opened handler has run
    match ev {
        Opened e => {
            if k.step < 10 {
                if goose_io::is_listener(e.listener) && k.accepted_role(e.listener) == 3 { io.set_keep_open_on_eof(e.link, true); }
            } else if k.step >= 20 {
                if goose_io::is_listener(e.listener) && k.accepted_role(e.listener) == 1 { io.send(e.link, "hi"); io.shutdown_write(e.link); }
                else if !goose_io::is_listener(e.listener) && k.role(e.link) == 0 { io.set_keep_open_on_eof(e.link, true); }
            }
        },
        _ => {},
    }
    if k.step == 0 {
        k.connect_local(io, 0);
        io.set_keep_open_on_eof(k.link[0], true);       // while it is dialling
        k.connect_local(io, 1);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) && k.pair_open(1) {
        io.send(k.link[1], "hi");
        io.shutdown_write(k.link[1]);
        io.send(k.link[2], "hi");
        io.shutdown_write(k.link[2]);
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'E') >= 1 && k.count(3, 'E') >= 1 {
        k.expect(k.received(0) == "hi" && k.received(3) == "hi", "keep-open set while dialling or in Opened: the Data did not arrive before PeerEof");
        k.expect(k.count(0, 'E') == 1 && k.count(3, 'E') == 1, "PeerEof was not delivered exactly once");
        k.expect(io.send(k.link[0], "ok") == goose_io::SendStatus.Sent && io.send(k.link[3], "ok") == goose_io::SendStatus.Sent, "the link did not stay open for sending after PeerEof");
        io.close(k.link[0]);
        io.close(k.link[3]);
        k.step = 3;
    } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
        // a late call has no effect
        k.recs.clear();
        k.live = 0;
        k.connect_local(io, 0);
        k.step = 10;
    } else if k.step == 10 && k.pair_open(0) {
        io.send(k.link[0], "bytes");
        k.step = 11;
    } else if k.step == 11 && k.count(1, 'D') >= 1 {
        io.set_keep_open_on_eof(k.link[1], true);       // after its Opened handler has returned: no effect
        io.shutdown_write(k.link[0]);                   // the peer finishes
        k.step = 12;
    } else if k.step == 12 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.count(1, 'E') == 0, "a keep-open call made after Opened was honoured: PeerEof was delivered");
        k.expect(k.closed_with(1, goose_io::CloseReason.PeerClosed), "after a late keep-open call the link did not close with PeerClosed");
        // an end of stream that arrives before the Opened handler of the dialled end has run
        k.recs.clear();
        k.live = 0;
        k.connect_local(io, 0);
        k.step = 20;
    } else if k.step == 20 && k.count(0, 'E') >= 1 {
        k.expect(k.received(0) == "hi" && k.count(0, 'E') == 1, "an end of stream that arrived before Opened was handled was not delivered as Data and one PeerEof");
        k.expect(io.send(k.link[0], "ok") == goose_io::SendStatus.Sent, "the link did not stay open for sending");
        io.close(k.link[0]);
        k.step = 21;
        k.finish();
    }
}

// Runs the checks of the half-close group: true if the check is one of them.
fn states_half_close_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 360 { c_states_half_close(k, io, ev); return true; }
    if k.id == 361 { c_states_keep_open(k, io, ev); return true; }
    return false;
}

// --- the sizing group ------------------------------------------------------------------------------------------------

// 362: send2 and send_room while the link is dialling, open, closing and ended.
fn c_states_sizing<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.expect(io.send2(k.link[0], "ab", "cd") == goose_io::SendStatus.NotOpen, "send2 on a dialling link did not return NotOpen");
        k.expect(io.send_room(k.link[0]) == 0, "send_room of a dialling link was not 0");
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(io.send_room(k.link[0]) > 0, "send_room of an open link was 0");
        k.expect(io.send2(k.link[0], "ab", "cd") == goose_io::SendStatus.Sent, "send2 on an open link did not return Sent");
        io.close(k.link[0]);
        k.expect(io.send2(k.link[0], "ab", "cd") == goose_io::SendStatus.Closed, "send2 on a closing link did not return Closed");
        k.expect(io.send_room(k.link[0]) == 0, "send_room of a closing link was not 0");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(io.send2(k.link[0], "ab", "cd") == goose_io::SendStatus.Closed, "send2 on an ended link did not return Closed");
        k.expect(io.send_room(k.link[0]) == 0, "send_room of an ended link was not 0");
        k.finish();
    }
}

// Runs the checks of the sizing group: true if the check is one of them.
fn states_sizing_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 362 { c_states_sizing(k, io, ev); return true; }
    return false;
}

// --- the abort group --------------------------------------------------------------------------------------------------

// 363: reset a dial in progress, and reset after close.
fn c_states_reset<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        io.reset(k.link[0]);                    // the dial has not opened yet
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a dial that was reset did not give exactly one Closed and no Opened");
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "a dial that was reset did not close with reason Local");
        k.connect_local(io, 1);
        k.step = 2;
    } else if k.step == 2 && k.pair_open(1) {
        io.close(k.link[2]);
        io.reset(k.link[2]);                    // after close, before its Closed
        k.step = 3;
    } else if k.step == 3 && k.first(2, 'C') >= 0 && k.first(3, 'C') >= 0 {
        k.t = io.now_ms();
        k.step = 4;
    } else if k.step == 4 && io.now_ms() >= k.t + 150 {
        k.expect(k.count(2, 'C') == 1 && k.closed_with(2, goose_io::CloseReason.Local), "reset after close did not leave exactly one Closed with reason Local");
        k.finish();
    }
}

// Runs the checks of the abort group: true if the check is one of them.
fn states_abort_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 363 { c_states_reset(k, io, ev); return true; }
    return false;
}

// --- the inspection group -------------------------------------------------------------------------------------------

// 364: peer_address while the link is dialling, open, closing and ended.
fn c_states_inspection<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.expect(goose_io::is_empty(io.peer_address(k.link[0])), "peer_address of a dialling link was not empty");
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let open = io.peer_address(k.link[0]);
        k.expect(!goose_io::is_empty(open), "peer_address of an open link was empty");
        io.close(k.link[0]);
        let closing = io.peer_address(k.link[0]);
        k.expect(closing.text[..] == open.text[..], "peer_address of a closing link was not the address it had while open");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(goose_io::is_empty(io.peer_address(k.link[0])), "peer_address of an ended link was not empty");
        k.finish();
    }
}

// Runs the checks of the inspection group: true if the check is one of them.
fn states_inspection_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 364 { c_states_inspection(k, io, ev); return true; }
    return false;
}
