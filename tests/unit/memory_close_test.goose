// In-memory provider: closing, resetting, the peer's end of stream, half-close, reasons, stale handles.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

let PeerClosed = goose_io::CloseReason.PeerClosed;
let PeerReset = goose_io::CloseReason.PeerReset;
let Local = goose_io::CloseReason.Local;

// --- close after a reply -------------------------------------------------------------------------

fn reply_event(p: kit::Pair&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    p.depth++;
    kit::check(p.depth == 1, "close, reset and send never deliver an event before they return");
    if kit::track(p, log, io, ev) { io.send(p.client, "ping, and more that is never read"); }
    match ev {
        Data d => {
            if d.tag == 1 {
                kit::check(d.bytes == "ping", "fixture: the closing end has input it has not read");
                kit::check(io.send(d.link, "the whole reply") == goose_io::SendStatus.Sent, "fixture: reply");
                io.close(d.link);
                io.close(d.link);       // a second close has no effect
                io.reset(d.link);       // nor a reset after close
            }
        },
        Closed c => { io.close(c.link); },      // closing inside Closed has no effect
        _ => {},
    }
    kit::stop_after(io, ev, 200);
    p.depth--;
}

fn close_after_reply() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    io.cfg.read_chunk = 4;
    var p = kit::Pair { .. };
    kit::connect(io, p, "127.0.0.1:8100");
    io.serve() { io, ev => reply_event(p, log, io, ev); };
    kit::check(kit::data_of(log, p.client) == "the whole reply", "the peer receives everything sent before close, even though the closing end left input unread");
    kit::check(kit::count_for(log, kit::CLOSED, p.client) == 1 && kit::count_for(log, kit::OPENED, p.client) == 1, "then its link ends");
    kit::check(kit::closed_once(log, p.client, PeerClosed), "with reason PeerClosed");
    kit::check(kit::kinds_of(log, p.server) == "ODC", "the closing end gets exactly one Closed, last");
    kit::check(kit::closed_once(log, p.server, Local), "with reason Local");
}

// --- no Data after close -------------------------------------------------------------------------

fn nodata_event(p: kit::Pair&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(p, log, io, ev) {
        io.send(p.client, "never seen");        // waits for the server end to read it
        io.close(p.server);                     // which closes first
    }
    kit::stop_after(io, ev, 200);
}

fn no_data_after_close() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    kit::connect(io, p, "127.0.0.1:8101");
    io.serve() { io, ev => nodata_event(p, log, io, ev); };
    kit::check(kit::kinds_of(log, p.server) == "OC", "no Data is delivered after close, even for bytes already received");
    kit::check(kit::closed_once(log, p.client, PeerClosed), "the other end sees a clean end");
}

// --- nothing but Closed after close --------------------------------------------------------------

struct Quiet { p: kit::Pair = kit::Pair { .. }, resumed: bool = false }

// The client has a Writable owed to it and a PeerEof on its way when it closes: neither arrives.
fn quiet_event(q: Quiet&, log: kit::Log&, chunk: u8[>..]&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(q.p, log, io, ev) {
        io.set_keep_open_on_eof(q.p.client, true);
        io.pause_reading(q.p.server, true);
        while io.send(q.p.client, chunk) == goose_io::SendStatus.Sent {}       // until Full: a Writable is owed
        io.shutdown_write(q.p.server);                                          // a PeerEof is on its way
        io.close(q.p.client);
        kit::check(io.send(q.p.client, "x") == goose_io::SendStatus.Closed, "send after close returns Closed");
        kit::check(io.send_room(q.p.client) == 0, "send_room after close is 0");
    }
    match ev {
        Tick t => { if !q.resumed { q.resumed = true; io.pause_reading(q.p.server, false); } },     // room opens
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn only_closed_after_close() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    var log = kit::Log { .. };
    var q = Quiet { .. };
    var chunk: u8[>..] = [];
    for i in 1000 { chunk.push('q'); }
    kit::connect(io, q.p, "127.0.0.1:8109");
    io.serve() { io, ev => quiet_event(q, log, chunk, io, ev); };
    kit::check(kit::kinds_of(log, q.p.client) == "OC", "after close the only event of the link is its Closed: no Writable, no PeerEof");
    kit::check(kit::closed_once(log, q.p.client, Local), "with reason Local");
    kit::check(kit::data_of(log, q.p.server).len == 8000, "and what was accepted before close still reached the peer");
}

// Closing a link from another link's handler, when an event for it is already on its way in the
// same pass: that event is not delivered either.
struct Two {
    a_client: goose_io::Link = goose_io::Link { .. },
    a_server: goose_io::Link = goose_io::Link { .. },
    b_client: goose_io::Link = goose_io::Link { .. },
    open:     i64            = 0,
    b_server: goose_io::Link = goose_io::Link { .. },
    fired:    bool           = false,
}

fn two_event(t: Two&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if e.tag == 1 { t.a_server = e.link; }
            if e.tag == 3 { t.b_server = e.link; }
            t.open++;
            if t.open == 4 { io.set_keep_open_on_eof(t.b_client, true); }
        },
        Tick k => {
            if !t.fired && t.open == 4 {
                t.fired = true;
                io.send(t.a_server, "go");              // next pass: Data for a_client ...
                io.shutdown_write(t.b_server);          // ... and, after it, PeerEof for b_client
            }
        },
        Data d => { if d.tag == 2 { io.close(t.b_client); } },
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn close_cancels_pending_events() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var t = Two { .. };
    let la, ea = io.listen("127.0.0.1:8110", 1);
    let lb, eb = io.listen("127.0.0.1:8111", 3);
    t.a_client = io.dial("127.0.0.1:8110", 2, 0);
    t.b_client = io.dial("127.0.0.1:8111", 4, 0);
    io.serve() { io, ev => two_event(t, log, io, ev); };
    kit::check(kit::count_for(log, kit::DATA, t.a_client) == 1, "fixture: the other link's Data was delivered");
    kit::check(kit::kinds_of(log, t.b_client) == "OC", "an event already on its way when the link is closed is not delivered");
    kit::check(kit::closed_once(log, t.b_client, Local), "only its Closed, with reason Local");
}

// --- reset ---------------------------------------------------------------------------------------

struct Reset { p: kit::Pair = kit::Pair { .. }, resumed: bool = false }

fn reset_event(r: Reset&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(r.p, log, io, ev) {
        io.pause_reading(r.p.client, true);
        kit::check(io.send(r.p.server, "queued and then discarded") == goose_io::SendStatus.Sent, "fixture: bytes queued");
        io.reset(r.p.server);
        kit::check(io.send(r.p.server, "x") == goose_io::SendStatus.Closed, "send after reset returns Closed");
    }
    match ev {
        Tick t => { if !r.resumed { r.resumed = true; io.pause_reading(r.p.client, false); } },
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn resetting() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var r = Reset { .. };
    kit::connect(io, r.p, "127.0.0.1:8102");
    io.serve() { io, ev => reset_event(r, log, io, ev); };
    kit::check(kit::closed_once(log, r.p.server, Local), "the reset link gets one Closed with reason Local");
    kit::check(kit::closed_once(log, r.p.client, PeerReset), "the peer's link ends with reason PeerReset");
    kit::check(kit::kinds_of(log, r.p.client) == "OC", "the unsent bytes were discarded");

    // reset on a dial that has not opened: cancelled like close
    var io2 = goose_io_memory::Loop { .. };
    var log2 = kit::Log { .. };
    let l, err = io2.listen("127.0.0.1:8103", 1);
    let d = io2.dial("127.0.0.1:8103", 2, 0);
    io2.reset(d);
    io2.serve() { io, ev => { kit::note(log2, io, ev); kit::stop_after(io, ev, 200); } };
    kit::check(kit::kinds_of(log2, d) == "C", "reset before Opened: no Opened, one Closed");
    kit::check(kit::closed_once(log2, d, Local), "with reason Local");
    kit::check(kit::count(log2, kit::OPENED) == 0, "and the listener never sees the link");
}

// --- the peer's end of stream: the default -------------------------------------------------------

fn eof_event(p: kit::Pair&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(p, log, io, ev) {
        io.send(p.client, "request");
        io.shutdown_write(p.client);
        kit::check(io.send(p.client, "more") == goose_io::SendStatus.Closed, "send after shutdown_write returns Closed");
        kit::check(io.send_room(p.client) == 0, "send_room after shutdown_write is 0");
        io.shutdown_write(p.client);            // twice: no effect
    }
    match ev {
        Data d => { if d.tag == 1 { io.send(d.link, "sent before the end"); } },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn default_end_of_stream() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    kit::connect(io, p, "127.0.0.1:8104");
    io.serve() { io, ev => eof_event(p, log, io, ev); };
    kit::check(kit::data_of(log, p.server) == "request", "bytes sent before shutdown_write arrive");
    kit::check(kit::kinds_of(log, p.server) == "ODC", "without opting in, the peer's end of stream closes the link, with no PeerEof");
    kit::check(kit::closed_once(log, p.server, PeerClosed), "with reason PeerClosed");
    kit::check(kit::data_of(log, p.client) == "sent before the end", "what the library had sent still reaches the peer");
    kit::check(kit::kinds_of(log, p.client) == "ODC", "the half-closed end still receives, then closes");
    kit::check(kit::closed_once(log, p.client, PeerClosed), "with reason PeerClosed once both sides have finished");
}

// --- the peer's end of stream: opted in ----------------------------------------------------------

struct Half { p: kit::Pair = kit::Pair { .. }, eof_at: i64 = -1, replied: bool = false, close_instead: bool = false }

fn half_event(h: Half&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(h.p, log, io, ev) {
        io.set_keep_open_on_eof(h.p.server, true);
        io.send(h.p.client, "req");
        io.send(h.p.client, "uest");
        io.shutdown_write(h.p.client);
    }
    match ev {
        PeerEof e => { h.eof_at = io.now_ms(); },
        Tick t => {
            // well after the peer finished, the link is still open for sending
            if h.eof_at >= 0 && !h.replied && t.now_ms >= h.eof_at + 100 {
                h.replied = true;
                kit::check(io.send_room(h.p.server) > 0, "after PeerEof the link is still open for sending");
                kit::check(io.send(h.p.server, "late reply") == goose_io::SendStatus.Sent, "a send after PeerEof is accepted");
                if h.close_instead { io.close(h.p.server); } else { io.shutdown_write(h.p.server); }
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 500);
}

fn half_close(close_instead: bool) {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var h = Half { close_instead: close_instead, .. };
    kit::connect(io, h.p, "127.0.0.1:8105");
    io.serve() { io, ev => half_event(h, log, io, ev); };
    kit::check(kit::data_of(log, h.p.server) == "request", "fixture: the request arrived");
    kit::check(kit::kinds_of(log, h.p.server) == "ODEC", "PeerEof comes once, after all Data, and Closed follows the answer");
    kit::check(kit::closed_once(log, h.p.server, if close_instead { Local } else { PeerClosed }), "the reason says who ended it");
    kit::check(kit::data_of(log, h.p.client) == "late reply", "the peer receives the whole reply");
    kit::check(kit::kinds_of(log, h.p.client) == "ODC", "followed by the end of the stream");
    kit::check(kit::closed_once(log, h.p.client, PeerClosed), "a clean end");
}

// --- sending to a peer that has gone -------------------------------------------------------------

struct Gone { p: kit::Pair = kit::Pair { .. }, sent: bool = false }

fn gone_event(g: Gone&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(g.p, log, io, ev) {
        io.set_keep_open_on_eof(g.p.client, true);
        io.close(g.p.server);
    }
    match ev {
        PeerEof e => {
            kit::check(io.send(e.link, "into the void") == goose_io::SendStatus.Sent, "a send to a peer that closed is accepted");
            g.sent = true;
        },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn peer_gone() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var g = Gone { .. };
    kit::connect(io, g.p, "127.0.0.1:8106");
    io.serve() { io, ev => gone_event(g, log, io, ev); };
    kit::check(g.sent, "fixture: PeerEof was delivered");
    kit::check(kit::kinds_of(log, g.p.client) == "OEC", "and then the link ends");
    kit::check(kit::closed_once(log, g.p.client, PeerReset), "with reason PeerReset: the bytes were lost");
}

// --- the provider's own reasons ------------------------------------------------------------------

fn policy_event(p: kit::Pair&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(p, log, io, ev) {
        io.close_with_reason(p.server, goose_io::CloseReason.LoopSpecific { code: 77 });
    }
    kit::stop_after(io, ev, 200);
}

fn provider_reasons() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    kit::connect(io, p, "127.0.0.1:8107");
    io.serve() { io, ev => policy_event(p, log, io, ev); };
    let i = kit::first_for(log, kit::CLOSED, p.server);
    kit::check(i >= 0 && kit::count_for(log, kit::CLOSED, p.server) == 1, "a link the provider closed on its own gets one Closed");
    if i >= 0 {
        let why = log.entries[i].why;
        kit::check(!goose_io::is_portable(why), "carrying the provider's own reason");
        match why {
            LoopSpecific r => { kit::check(r.code == 77, "and its code"); },
            _ => { kit::check(false, "the reason is LoopSpecific"); },
        }
    }
    kit::check(kit::closed_once(log, p.client, PeerClosed), "the other end sees a clean end");
}

// --- stale handles after the slot is used again --------------------------------------------------

struct Stale {
    first:       goose_io::Link = goose_io::Link { .. },
    second:      goose_io::Link = goose_io::Link { .. },
    reuser:      goose_io::Link = goose_io::Link { .. }, // the later link that got the first one's slot
    second_open: bool           = false,
    checked:     bool           = false,
}

fn stale_event(s: Stale&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if goose_io::same(e.link, s.first) { io.close(s.first); }
            if goose_io::same(e.link, s.second) { s.second_open = true; }
            if goose_io::is_valid(s.second) {
                io.set_user(e.link, 9);
                if e.link.slot == s.first.slot { s.reuser = e.link; }
            }
        },
        Closed c => {
            if goose_io::same(c.link, s.first) {
                kit::check(io.user(c.link) == 5, "the handle is still valid while its Closed is handled");
                kit::check(!goose_io::is_empty(io.peer_address(c.link)), "and so is its peer address");
                kit::check(io.send(c.link, "x") == goose_io::SendStatus.Closed, "though nothing can be sent on it");
            }
        },
        Tick t => {
            if !goose_io::is_valid(s.second) && kit::count_for(log, kit::CLOSED, s.first) == 1 {
                s.second = io.dial("127.0.0.1:8108", 2, 0);
                io.set_user(s.second, 9);
            }
            if s.second_open && !s.checked {
                s.checked = true;
                kit::check(goose_io::is_valid(s.reuser), "fixture: the provider used the slot again");
                kit::check(!goose_io::same(s.first, s.reuser), "a reused slot gives a different handle");
                // every operation on the old handle is a no-op and leaves the new link alone
                kit::check(io.send(s.first, "x") == goose_io::SendStatus.Closed, "send on the stale handle returns Closed");
                io.set_user(s.first, 1234);
                kit::check(io.user(s.first) == 0, "user on the stale handle is 0: the handle went stale when its Closed handler returned");
                kit::check(io.user(s.reuser) == 9, "set_user on the stale handle did not touch the link now in its slot");
                kit::check(goose_io::is_empty(io.peer_address(s.first)), "peer_address on the stale handle is empty");
                io.pause_reading(s.first, true);
                io.set_keep_open_on_eof(s.first, true);
                io.shutdown_write(s.first);
                io.close(s.first);
                io.reset(s.first);
                kit::check(io.send(s.reuser, "still here") == goose_io::SendStatus.Sent, "the link now in its slot is unaffected");
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 600);
}

fn stale_handles() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Stale { .. };
    let l, err = io.listen("127.0.0.1:8108", 1);
    s.first = io.dial("127.0.0.1:8108", 2, 0);
    io.set_user(s.first, 5);
    io.serve() { io, ev => stale_event(s, log, io, ev); };
    kit::check(s.checked, "fixture: the second link opened");
    kit::check(kit::count_for(log, kit::CLOSED, s.first) == 1, "the old link still has exactly one Closed");
    kit::check(kit::count(log, kit::DATA) == 1, "and the link now in its slot carried its data");
    kit::check(kit::count(log, kit::CLOSED) == 4, "four links, four Closed");
}

fn main() {
    close_after_reply();
    no_data_after_close();
    only_closed_after_close();
    close_cancels_pending_events();
    resetting();
    default_end_of_stream();
    half_close(false);
    half_close(true);
    peer_gone();
    provider_reasons();
    stale_handles();
    kit::finish();
}
