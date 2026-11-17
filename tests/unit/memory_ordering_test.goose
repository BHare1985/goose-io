// In-memory event loop: adversarial event ordering. Each case arranges for two or more events to be
// queued in one pass and for the handler of the earlier one to act on the link of the later one, or
// for an operation to be made where it is most likely to go wrong: inside a handler, inside the
// link's own Closed, before an Opened. The links are made so that slot order, which is the order in
// which Data and end-of-stream records are queued, puts the acting link first.
//
//   slot 0 c1 (dialled)    slot 1 c2 (dialled)    slot 2 a1 (accepted, peer of c1)    slot 3 a2 (peer of c2)
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

struct Four {
    c1:     goose_io::Link = goose_io::Link { .. },
    c2:     goose_io::Link = goose_io::Link { .. },
    a1:     goose_io::Link = goose_io::Link { .. },
    a2:     goose_io::Link = goose_io::Link { .. },
    mode:   i64            = 0,
    act:    bool           = true,
    opened: i64            = 0,
    fired:  bool           = false,
    acted:  bool           = false,
}

let CLOSE_WHILE_WRITABLE = 0;       // a1 has a Writable queued; the handler of c2's Data closes it
let SHUT_WHILE_WRITABLE = 1;        // the same, with shutdown_write
let CLOSE_WITH_DATA = 2;            // c2 has Data queued; the handler of c1's Data closes it
let CLOSE_WITH_EOF = 3;             // c2 has an end of stream queued, and asked to see it
let RESET_WITH_PEER_DATA = 4;       // c2 is reset while its peer a2 has Data queued
let STOP_WITH_EVENTS = 5;           // c1's Data handler stops the loop while c2 has Data queued

fn small(io: goose_io_memory::Loop&) {
    io.cfg.link_buffer = 4096;
    io.cfg.max_send = 4096;
}

// When all four links are open: set the scene so that the next pass queues the events of the mode.
fn arrange(f: Four&, io: goose_io_memory::Loop&) {
    if f.mode == CLOSE_WHILE_WRITABLE || f.mode == SHUT_WHILE_WRITABLE {
        io.pause_reading(f.c1, true);
        var filler: u8[4096] = [65; 4096];
        io.send(f.a1, filler[..]);
        kit::check(io.send(f.a1, "y") == goose_io::SendStatus.Full, "fixture: a1 is refused");
    } else if f.mode == CLOSE_WITH_DATA || f.mode == STOP_WITH_EVENTS {
        io.send(f.a1, "to c1");
        io.send(f.a2, "to c2");
    } else if f.mode == CLOSE_WITH_EOF {
        io.set_keep_open_on_eof(f.c2, true);
        io.send(f.a1, "to c1");
        io.shutdown_write(f.a2);
    } else if f.mode == RESET_WITH_PEER_DATA {
        io.send(f.a1, "to c1");
        io.send(f.c2, "to a2");
    }
}

// The handler of c1 (or, in the writable modes, of c2) acts on the link that has events queued.
fn act(f: Four&, io: goose_io_memory::Loop&) {
    guard f.act && !f.acted else { return; }
    f.acted = true;
    if f.mode == CLOSE_WHILE_WRITABLE { io.close(f.a1); }
    else if f.mode == SHUT_WHILE_WRITABLE { io.shutdown_write(f.a1); }
    else if f.mode == CLOSE_WITH_DATA || f.mode == CLOSE_WITH_EOF { io.close(f.c2); }
    else if f.mode == RESET_WITH_PEER_DATA { io.reset(f.c2); }
    else if f.mode == STOP_WITH_EVENTS { io.stop(0); }
}

fn four_event(f: Four&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if !goose_io::is_listener(e.listener) { if !goose_io::is_valid(f.c1) { f.c1 = e.link; } else { f.c2 = e.link; } }
            else { if !goose_io::is_valid(f.a1) { f.a1 = e.link; } else { f.a2 = e.link; } }
            f.opened++;
            if f.opened == 4 { arrange(f, io); }
        },
        Data d => {
            // in the writable modes c1 reads and so opens room for a1; the acting link is c2
            if f.mode == CLOSE_WHILE_WRITABLE || f.mode == SHUT_WHILE_WRITABLE {
                if goose_io::same(d.link, f.c2) { act(f, io); }
            } else if goose_io::same(d.link, f.c1) {
                act(f, io);
            }
        },
        Tick t => {
            if (f.mode == CLOSE_WHILE_WRITABLE || f.mode == SHUT_WHILE_WRITABLE) && !f.fired && t.now_ms >= 50 {
                f.fired = true;
                io.pause_reading(f.c1, false);      // c1 reads next pass: a Writable is owed to a1
                io.send(f.a2, "go");                // and c2 has Data queued in the same pass, after c1's
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 400);
}

fn run_four(mode: i64, act: bool, log: kit::Log&) -> Four {
    var io = goose_io_memory::Loop { .. };
    small(io);
    var f = Four { mode: mode, act: act, .. };
    let l, err = io.listen("127.0.0.1:9001");
    io.dial("127.0.0.1:9001", 0);
    io.dial("127.0.0.1:9001", 0);
    io.serve() { io, ev => four_event(f, log, io, ev); };
    return f;
}

fn closed_while_writable_is_owed() {
    // the fixture works: left alone, a1 gets its Writable
    var log0 = kit::Log { .. };
    let f0 = run_four(CLOSE_WHILE_WRITABLE, false, log0);
    kit::check(kit::count_for(log0, kit::WRITABLE, f0.a1) == 1, "fixture: with nothing done, a Writable is delivered to a1");

    var log = kit::Log { .. };
    let f = run_four(CLOSE_WHILE_WRITABLE, true, log);
    kit::check(f.acted, "fixture: c2's Data was delivered and closed a1");
    kit::check(kit::kinds_of(log, f.a1) == "OC", "a link closed while a Writable is queued for it gets no Writable, only its Closed");
    kit::check(kit::closed_once(log, f.a1, goose_io::CloseReason.Local), "with reason Local");
}

fn write_side_shut_while_writable_is_owed() {
    var log = kit::Log { .. };
    let f = run_four(SHUT_WHILE_WRITABLE, true, log);
    kit::check(f.acted, "fixture: c2's Data was delivered and shut a1's write side");
    kit::check(kit::count_for(log, kit::WRITABLE, f.a1) == 0, "a link whose write side is shut while a Writable is queued gets no Writable");
}

fn closed_with_data_queued() {
    var log = kit::Log { .. };
    let f = run_four(CLOSE_WITH_DATA, true, log);
    kit::check(f.acted && kit::data_of(log, f.c1) == "to c1", "fixture: c1's Data was delivered first");
    kit::check(kit::kinds_of(log, f.c2) == "OC", "a link closed while Data is queued for it gets only its Closed");
}

fn closed_with_end_of_stream_queued() {
    var log = kit::Log { .. };
    let f = run_four(CLOSE_WITH_EOF, true, log);
    kit::check(f.acted, "fixture: c1's Data was delivered first");
    kit::check(kit::kinds_of(log, f.c2) == "OC", "a link closed while its PeerEof is queued gets only its Closed");
}

fn reset_with_peer_data_queued() {
    var log = kit::Log { .. };
    let f = run_four(RESET_WITH_PEER_DATA, true, log);
    kit::check(f.acted, "fixture: c1's Data was delivered first");
    kit::check(kit::kinds_of(log, f.a2) == "OC", "the peer of a reset link, with Data queued, gets only its Closed");
    kit::check(kit::closed_once(log, f.a2, goose_io::CloseReason.PeerReset), "with reason PeerReset");
}

fn stop_with_events_queued() {
    var log = kit::Log { .. };
    let f = run_four(STOP_WITH_EVENTS, true, log);
    kit::check(f.acted && log.entries.len > 0, "fixture: the handler of c1's Data stopped the loop");
    kit::check(kit::data_of(log, f.c2) == "to c2", "an event queued for another link before stop is still delivered");
    for link in [f.c1, f.c2, f.a1, f.a2] {
        let kinds = kit::kinds_of(log, link);
        kit::check(kinds.len >= 2 && kinds[kinds.len - 1] == 'C' && kit::count_for(log, kit::CLOSED, link) == 1, "every link ends with exactly one Closed, last");
    }
    kit::check(kit::closed_once(log, f.c2, goose_io::CloseReason.Shutdown), "a link still open at stop(0) closes with Shutdown");
}

// --- operations inside a link's own Closed handler -----------------------------------------------

struct Own { p: kit::Pair = kit::Pair { .. }, sent: goose_io::SendStatus = goose_io::SendStatus.Sent, room: i64 = -1, ran: bool = false }

fn own_closed_event(o: Own&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(o.p, log, io, ev) { io.close(o.p.client); }
    match ev {
        Closed c => {
            if goose_io::same(c.link, o.p.client) {
                o.ran = true;
                o.sent = io.send(c.link, "late");
                o.room = io.send_room(c.link);
                io.shutdown_write(c.link);
                io.pause_reading(c.link, false);
                io.set_keep_open_on_eof(c.link, true);
                io.reset(c.link);
                io.close(c.link);
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn operations_in_own_closed() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var o = Own { .. };
    kit::connect(io, o.p, "127.0.0.1:9002");
    io.serve() { io, ev => own_closed_event(o, log, io, ev); };
    kit::check(o.ran, "fixture: the Closed handler ran");
    kit::check(o.sent == goose_io::SendStatus.Closed && o.room == 0, "inside its own Closed a link takes no sends and has no room");
    kit::check(kit::kinds_of(log, o.p.client) == "OC", "and nothing the handler does gives the link another event");
    kit::check(kit::kinds_of(log, o.p.server) == "ODC" || kit::kinds_of(log, o.p.server) == "OC", "the other end sees a clean end");
}

// --- a dialled end closed before its own Opened --------------------------------------------------

struct Early { c: goose_io::Link = goose_io::Link { .. } }

fn closed_before_opened() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var e = Early { .. };
    let l, err = io.listen("127.0.0.1:9003");
    e.c = io.dial("127.0.0.1:9003", 0);
    io.serve() { io, ev =>
        kit::note(log, io, ev);
        match ev {
            Opened o => { if goose_io::is_listener(o.listener) { io.close(e.c); } },     // the accepted end opens first
            _ => {},
        }
        kit::stop_after(io, ev, 200);
    };
    kit::check(kit::kinds_of(log, e.c) == "C" && kit::closed_once(log, e.c, goose_io::CloseReason.Local), "a dialled end closed by the other's Opened handler gets one Closed and no Opened");
    var accepted = goose_io::Link { .. };
    for en in log.entries { if en.kind == kit::OPENED && goose_io::is_listener(en.listener) { accepted = en.link; } }
    kit::check(kit::kinds_of(log, accepted) == "OC" && kit::closed_once(log, accepted, goose_io::CloseReason.PeerClosed), "and the accepted end sees a clean end");
}

// --- several events in one pass, in order, with Data split -----------------------------------------

struct Split { p: kit::Pair = kit::Pair { .. } }

fn split_event(s: Split&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(s.p, log, io, ev) { io.send(s.p.client, "0123456789"); io.send(s.p.client, "abc"); }
    kit::stop_after(io, ev, 200);
}

fn data_split_in_order() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.read_chunk = 4;
    var log = kit::Log { .. };
    var s = Split { .. };
    kit::connect(io, s.p, "127.0.0.1:9004");
    io.serve() { io, ev => split_event(s, log, io, ev); };
    kit::check(kit::data_of(log, s.p.server) == "0123456789abc", "input split by read_chunk arrives in order");
    kit::check(kit::count_for(log, kit::DATA, s.p.server) == 4, "in pieces of at most four bytes");
    kit::check(kit::first_for(log, kit::OPENED, s.p.server) < kit::first_for(log, kit::DATA, s.p.server), "Opened comes before Data");
    var passes_ended = 0;
    var misplaced = 0;
    for en, i in log.entries {
        if en.kind == kit::PASS_END {
            passes_ended++;
            if i == 0 || log.entries[i - 1].kind == kit::PASS_END { misplaced++; }
        }
    }
    kit::check(passes_ended >= 2 && misplaced == 0, "PassEnd follows link events and never comes twice in a row");
    kit::check(log.entries[log.entries.len - 1].kind == kit::PASS_END, "the last event of the run is the PassEnd of the pass that closed the links");
}

fn same_run_twice() {
    var first = kit::Log { .. };
    var second = kit::Log { .. };
    run_four(STOP_WITH_EVENTS, true, first);
    run_four(STOP_WITH_EVENTS, true, second);
    kit::check(first.entries.len > 8 && kit::text(first) == kit::text(second), "the same arrangement gives the same events at the same times");
}

fn main() {
    closed_while_writable_is_owed();
    write_side_shut_while_writable_is_owed();
    closed_with_data_queued();
    closed_with_end_of_stream_queued();
    reset_with_peer_data_queued();
    stop_with_events_queued();
    operations_in_own_closed();
    closed_before_opened();
    data_split_in_order();
    same_run_twice();
    kit::finish();
}
