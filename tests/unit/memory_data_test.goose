// In-memory event loop: sending, receiving, backpressure, pausing.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn pattern(n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for i in n { out.push(('a' + i % 26) as u8); }
    return out;
}

// --- small sends, order, send2 -------------------------------------------------------------------

fn basics_event(p: kit::Pair&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    p.depth++;
    kit::check(p.depth == 1, "no event is delivered inside an operation");
    if kit::track(p, log, io, ev) {
        kit::check(io.send(p.client, "") == goose_io::SendStatus.Sent, "a send of zero bytes on an open link returns Sent");
        kit::check(io.send(p.client, "one,") == goose_io::SendStatus.Sent, "a small send is accepted");
        kit::check(io.send(p.client, "two,") == goose_io::SendStatus.Sent, "a second send is accepted");
        kit::check(io.send2(p.client, "head:", "body") == goose_io::SendStatus.Sent, "send2 is accepted");
        kit::check(io.send2(p.client, "", ",tail") == goose_io::SendStatus.Sent, "send2 with an empty first part");
        kit::check(io.send2(p.client, "", "") == goose_io::SendStatus.Sent, "send2 of nothing returns Sent");
        kit::check(io.send(p.server, "reply") == goose_io::SendStatus.Sent, "the accepted end sends too");
        // Sent means the event loop has the bytes: the caller's memory is its own again at once
        var mine: u8[>..] = [];
        mine.append(",original");
        kit::check(io.send(p.client, mine) == goose_io::SendStatus.Sent, "fixture: a send from a buffer");
        for &c in mine { c = 'X'; }
        mine.clear();
    }
    kit::stop_after(io, ev, 100);
    p.depth--;
}

fn basics() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    kit::connect(io, p, "127.0.0.1:8000");
    kit::check(io.max_send() >= 4096, "max_send is at least 4096");
    kit::check(io.send_room(p.client) == 0, "send_room is 0 before the link opens");
    io.serve() { io, ev => basics_event(p, log, io, ev); };
    kit::check(kit::data_of(log, p.server) == "one,two,head:body,tail,original", "bytes arrive in the order the sends were accepted, send2 parts joined, unchanged by what the caller does to its memory afterwards");
    kit::check(kit::data_of(log, p.client) == "reply", "bytes flow the other way");
}

// --- large transfers arrive as several lent slices -----------------------------------------------

struct Big { p: kit::Pair = kit::Pair { .. }, sent: i64 = 0, largest: i64 = 0 }

fn big_event(b: Big&, log: kit::Log&, payload: u8[>..]&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    let both = kit::track(b.p, log, io, ev);
    match ev {
        Data d => { if d.bytes.len > b.largest { b.largest = d.bytes.len; } },
        _ => {},
    }
    // send the payload in pieces, as much as fits, on open and on every Writable
    var again = both;
    match ev { Writable w => { again = true; }, _ => {} }
    if again {
        while b.sent < payload.len {
            let n = if payload.len - b.sent < 4096 { payload.len - b.sent } else { 4096 };
            let st = io.send(b.p.client, payload[b.sent..b.sent + n]);
            guard st == goose_io::SendStatus.Sent else { break; }
            b.sent += n;
        }
    }
    kit::stop_after(io, ev, 500);
}

fn large_transfer() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    io.cfg.read_chunk = 1000;
    var log = kit::Log { .. };
    var b = Big { .. };
    var payload = pattern(40000);
    kit::connect(io, b.p, "127.0.0.1:8001");
    io.serve() { io, ev => big_event(b, log, payload, io, ev); };
    kit::check(b.sent == 40000, "the whole payload was accepted over several Writable events");
    kit::check(kit::data_of(log, b.p.server) == payload, "a large transfer arrives intact and in order");
    kit::check(b.largest <= 1000, "one Data carries at most read_chunk bytes");
    kit::check(kit::count_for(log, kit::DATA, b.p.server) >= 40, "and so the transfer arrives as many Data events");
}

// --- Full, Writable, TooLarge, bounded memory ----------------------------------------------------

struct Back { p: kit::Pair = kit::Pair { .. }, accepted: i64 = 0, refused: i64 = 0, resumed: bool = false, after_writable: bool = false }

fn back_event(b: Back&, log: kit::Log&, chunk: u8[>..]&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(b.p, log, io, ev) {
        io.pause_reading(b.p.server, true);                 // a peer that reads nothing
        // offer far more than the bound; only what fits is taken
        for i in 100 {
            let st = io.send(b.p.client, chunk);
            if st == goose_io::SendStatus.Sent { b.accepted++; } else {
                kit::check(st == goose_io::SendStatus.Full, "a send that does not fit returns Full");
                b.refused++;
            }
        }
        kit::check(b.accepted == 8, "exactly what fits the bound is accepted (8 x 1000 of 8192)");
        kit::check(io.stored_bytes(b.p.client) == 8000, "the event loop holds what it accepted");
        kit::check(io.stored_bytes(b.p.client) <= io.cfg.link_buffer, "and never more than the per-link bound");
        kit::check(io.send_room(b.p.client) == 192, "send_room is what a send would accept now");
        // send2: the first part alone would fit, the two together do not: neither is taken
        kit::check(io.send2(b.p.client, "MARKER", chunk[..500]) == goose_io::SendStatus.Full, "send2 is refused whole");
        kit::check(io.stored_bytes(b.p.client) == 8000, "a refused send2 takes nothing");
        // larger than max_send: never fits
        kit::check(io.send(b.p.client, chunk[..0]) == goose_io::SendStatus.Sent, "zero bytes still fit");
        var huge: u8[>..] = [];
        huge.resize(io.max_send() + 1, 'x');
        kit::check(io.send(b.p.client, huge) == goose_io::SendStatus.TooLarge, "a send above max_send returns TooLarge");
        kit::check(io.send2(b.p.client, huge[..4000], huge[..97]) == goose_io::SendStatus.TooLarge, "send2 compares the two lengths added with max_send");
    }
    match ev {
        Tick t => {
            if t.now_ms >= 200 && !b.resumed {
                b.resumed = true;
                kit::check(b.p.writables == 0, "no Writable while the peer reads nothing");
                kit::check(kit::count_for(log, kit::DATA, b.p.server) == 0, "no Data while reading is paused");
                io.pause_reading(b.p.server, false);
            }
        },
        Writable w => {
            if !b.after_writable {
                b.after_writable = true;
                let room = io.send_room(w.link);
                kit::check(room > 0, "after Writable there is room");
                kit::check(io.send(w.link, chunk[..(if room < 1000 { room } else { 1000 })]) == goose_io::SendStatus.Sent, "a send no larger than send_room returns Sent");
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 600);
}

fn backpressure() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    io.cfg.read_chunk = 1000;       // the peer reads in eight pieces: room opens eight times, Writable comes once
    var log = kit::Log { .. };
    var b = Back { .. };
    var chunk = pattern(1000);
    kit::connect(io, b.p, "127.0.0.1:8002");
    io.serve() { io, ev => back_event(b, log, chunk, io, ev); };
    kit::check(b.refused == 92, "every send beyond the bound was refused");
    kit::check(b.p.writables == 1, "many refusals, exactly one Writable once room opened");
    let received = kit::data_of(log, b.p.server);
    kit::check(received.len == 9000, "the peer got exactly the accepted bytes");
    kit::check(received.find("MARKER") < 0, "nothing of the refused send2 reached the peer");
}

// --- Writable means the refused send fits --------------------------------------------------------

struct Fit { p: kit::Pair = kit::Pair { .. }, resumed: bool = false, reads_before: i64 = -1, room_at: i64 = -1, retry_ok: bool = false }

fn fit_event(f: Fit&, log: kit::Log&, chunk: u8[>..]&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(f.p, log, io, ev) {
        io.pause_reading(f.p.server, true);
        for i in 8 { kit::check(io.send(f.p.client, chunk) == goose_io::SendStatus.Sent, "fixture: fill the link"); }
        // room is 192: three refusals of different sizes, the largest first
        kit::check(io.send2(f.p.client, chunk, chunk) == goose_io::SendStatus.Full, "fixture: 2000 bytes refused");
        kit::check(io.send2(f.p.client, chunk, chunk[..500]) == goose_io::SendStatus.Full, "fixture: 1500 bytes refused");
        kit::check(io.send(f.p.client, chunk[..300]) == goose_io::SendStatus.Full, "fixture: 300 bytes refused");
    }
    match ev {
        Tick t => {
            if t.now_ms >= 100 && !f.resumed { f.resumed = true; io.pause_reading(f.p.server, false); }
        },
        Writable w => {
            if f.reads_before < 0 {
                f.reads_before = kit::count_for(log, kit::DATA, f.p.server);
                f.room_at = io.send_room(w.link);
                f.retry_ok = io.send2(w.link, chunk, chunk) == goose_io::SendStatus.Sent;
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 400);
}

fn writable_fits() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    io.cfg.read_chunk = 1000;       // room opens 1000 bytes at a time
    var log = kit::Log { .. };
    var f = Fit { .. };
    var chunk = pattern(1000);
    kit::connect(io, f.p, "127.0.0.1:8005");
    io.serve() { io, ev => fit_event(f, log, chunk, io, ev); };
    kit::check(f.p.writables == 1, "three refusals in a row share one Writable");
    kit::check(f.reads_before == 2, "Writable waits until the largest refused send fits (two reads of 1000), not for the first free byte");
    kit::check(f.room_at >= 2000, "when Writable is delivered send_room covers every send refused since the last one");
    kit::check(f.retry_ok, "so the refused send, tried again, returns Sent");
    kit::check(kit::data_of(log, f.p.server).len == 10000, "fixture: everything arrived");
}

// --- statuses on links that are not open ---------------------------------------------------------

struct Shut { p: kit::Pair = kit::Pair { .. }, closed_seen: bool = false }

fn shut_event(s: Shut&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(s.p, log, io, ev) {
        io.close(s.p.client);
        kit::check(io.send(s.p.client, "late") == goose_io::SendStatus.Closed, "send after close returns Closed");
        kit::check(io.send2(s.p.client, "la", "te") == goose_io::SendStatus.Closed, "send2 after close returns Closed");
        kit::check(io.send_room(s.p.client) == 0, "send_room after close is 0");
    }
    match ev {
        Closed c => {
            if goose_io::same(c.link, s.p.client) { s.closed_seen = true; }
        },
        Tick t => {
            if s.closed_seen {
                kit::check(io.send(s.p.client, "stale") == goose_io::SendStatus.Closed, "send on a stale handle returns Closed");
                kit::check(io.send_room(s.p.client) == 0, "send_room on a stale handle is 0");
                io.pause_reading(s.p.client, true);         // no effect, must not crash
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn not_open() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Shut { .. };
    kit::connect(io, s.p, "127.0.0.1:8003");
    kit::check(io.send(s.p.client, "early") == goose_io::SendStatus.NotOpen, "send before Opened returns NotOpen");
    kit::check(io.send(goose_io::Link { .. }, "x") == goose_io::SendStatus.Closed, "send on an invalid link returns Closed");
    io.serve() { io, ev => shut_event(s, log, io, ev); };
    kit::check(kit::data_of(log, s.p.server).len == 0, "nothing sent before Opened or after close was queued");
}

// --- pausing -------------------------------------------------------------------------------------

struct Pause { p: kit::Pair = kit::Pair { .. }, resumed: bool = false }

fn pause_event(s: Pause&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    if kit::track(s.p, log, io, ev) {
        io.pause_reading(s.p.server, true);
        kit::check(io.send(s.p.client, "held back") == goose_io::SendStatus.Sent, "a send to a paused peer is accepted while it fits");
    }
    match ev {
        Tick t => {
            if t.now_ms >= 300 && !s.resumed {
                s.resumed = true;
                io.pause_reading(s.p.server, false);
            }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 500);
}

fn pausing() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Pause { .. };
    kit::connect(io, s.p, "127.0.0.1:8004");
    io.serve() { io, ev => pause_event(s, log, io, ev); };
    let i = kit::first_for(log, kit::DATA, s.p.server);
    kit::check(i >= 0 && log.entries[i].at_ms >= 300, "no Data is delivered while reading is paused");
    kit::check(kit::data_of(log, s.p.server) == "held back", "the bytes are delivered after the resume");
}

// --- a refused send is always resolved -----------------------------------------------------------

fn small_buffers(io: goose_io_memory::Loop&) {
    io.cfg.link_buffer = 4096;
    io.cfg.max_send = 4096;
}

// Fills the link to the peer, then asks for one byte more: that send is refused.
fn fill_then_refuse(io: goose_io_memory::Loop&, link: goose_io::Link) -> bool {
    var filler: u8[4096] = [65; 4096];
    kit::check(io.send(link, filler[..]) == goose_io::SendStatus.Sent, "fixture: the first send fills the link");
    return io.send(link, "y") == goose_io::SendStatus.Full;
}

struct WriteShut { refused: bool = false, shut: bool = false, writable_after: i64 = 0, send_after: goose_io::SendStatus = goose_io::SendStatus.Sent, data: i64 = 0, eof: i64 = 0 }

// The peer reads (so a Writable is owed to the library) in the same pass in which an earlier-queued Data
// is delivered to the library, whose handler shuts the write side before the Writable is delivered.
fn write_shut_event(k: WriteShut&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => { io.set_keep_open_on_eof(e.link, true); k.refused = fill_then_refuse(io, e.link); },
        Data e => { k.data++; if !k.shut { k.shut = true; io.shutdown_write(e.link); } },
        PeerEof e => { k.eof++; },
        Writable e => { if k.shut { k.writable_after++; k.send_after = io.send(e.link, "z"); } },
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn no_writable_after_shutdown_write() {
    var io = goose_io_memory::Loop { .. };
    small_buffers(io);
    var k = WriteShut { .. };
    let l, err = io.listen("10.0.0.1:80");
    let p = io.add_peer();
    io.peer_connect(p, "10.0.0.1:80", 0);
    io.peer_stop_reading(p, 0);
    io.peer_resume_reading(p, 50);
    io.peer_send(p, 0, "x");
    io.peer_shutdown(p, 0);
    io.serve() { io, ev => write_shut_event(k, io, ev); };
    kit::check(k.refused, "fixture: the library was refused with Full");
    kit::check(k.shut && k.data == 1, "fixture: it shut its write side from the handler of a Data queued before the Writable");
    kit::check(k.writable_after == 0, "no Writable is delivered after shutdown_write, even one already queued");
    kit::check(k.eof == 1, "the link still receives the peer's end of stream");
}

fn shutdown_straight_after_full() {
    var io = goose_io_memory::Loop { .. };
    small_buffers(io);
    var writables = 0;
    var closed_status = goose_io::SendStatus.Sent;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.2:80");
    io.peer_stop_reading(p, 0);
    io.peer_resume_reading(p, 50);
    let link = io.dial("10.0.0.2:80", 0);
    io.serve() { io, ev =>
        match ev {
            Opened e => { fill_then_refuse(io, e.link); io.shutdown_write(e.link); closed_status = io.send(e.link, "z"); },
            Writable e => { writables++; },
            _ => {},
        }
        kit::stop_after(io, ev, 300);
    };
    kit::check(closed_status == goose_io::SendStatus.Closed, "fixture: a send after shutdown_write returns Closed");
    kit::check(io.peer_received(p).len == 4096, "fixture: the peer read everything that had been accepted");
    kit::check(writables == 0, "shutdown_write after a refusal gives no Writable when the peer later reads");
}

struct Vanish { refused: bool = false, writables: i64 = 0, eof: i64 = 0, retry: goose_io::SendStatus = goose_io::SendStatus.Full, closed: bool = false, why: goose_io::CloseReason = goose_io::CloseReason.Error }

fn vanish_event(k: Vanish&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => { io.set_keep_open_on_eof(e.link, true); k.refused = fill_then_refuse(io, e.link); },
        Writable e => { k.writables++; k.retry = io.send(e.link, "z"); },
        PeerEof e => { k.eof++; },
        Closed e => { k.closed = true; k.why = e.why; },
        _ => {},
    }
    kit::stop_after(io, ev, 5000);
}

fn full_when_the_peer_closes() {
    var io = goose_io_memory::Loop { .. };
    small_buffers(io);
    var k = Vanish { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.3:80");
    io.peer_stop_reading(p, 0);
    io.peer_close(p, 200);
    io.dial("10.0.0.3:80", 0);
    io.serve() { io, ev => vanish_event(k, io, ev); };
    kit::check(k.refused && k.eof == 1, "fixture: the library was refused, then the peer closed");
    let resolved = k.writables == 1 || (k.closed && k.why != goose_io::CloseReason.Shutdown);
    kit::check(resolved, "a Full is resolved by one Writable or by the link's Closed, not by the application's stop");
    kit::check(k.writables <= 1, "never by more than one Writable");
    if k.writables == 1 {
        kit::check(k.retry == goose_io::SendStatus.Sent || k.retry == goose_io::SendStatus.Closed, "the retry after that Writable is not refused again");
        kit::check(k.closed && k.why == goose_io::CloseReason.PeerReset, "and the link then ends, reset");
    }
}

fn default_link_closes_when_the_peer_closes() {
    var io = goose_io_memory::Loop { .. };
    small_buffers(io);
    var writables = 0;
    var why = goose_io::CloseReason.Error;
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.5:80");
    io.peer_stop_reading(p, 0);
    io.peer_close(p, 200);
    io.dial("10.0.0.5:80", 0);
    io.serve() { io, ev =>
        match ev {
            Opened e => { fill_then_refuse(io, e.link); },
            Writable e => { writables++; },
            Closed e => { why = e.why; },
            _ => {},
        }
        kit::stop_after(io, ev, 5000);
    };
    kit::check(writables == 0, "a link that does not keep itself open gets no Writable when the peer closes");
    kit::check(why == goose_io::CloseReason.PeerClosed, "it closes with PeerClosed");
}

struct Blocked { link: goose_io::Link = goose_io::Link { .. } }

fn library_closes_while_the_peer_is_refused() {
    var io = goose_io_memory::Loop { .. };
    small_buffers(io);
    var b = Blocked { .. };
    let l, err = io.listen("10.0.0.4:80");
    let p = io.add_peer();
    io.peer_connect(p, "10.0.0.4:80", 0);
    io.peer_send(p, 0, pattern(10000));
    io.serve() { io, ev =>
        match ev {
            Opened e => { b.link = e.link; io.pause_reading(e.link, true); },
            Tick t => { if t.now_ms >= 100 && b.link.gen != 0 { io.close(b.link); b.link = goose_io::Link { .. }; } },
            _ => {},
        }
        kit::stop_after(io, ev, 1000);
    };
    kit::check(io.peer_closed(p), "a peer whose send was refused is not left waiting when the library closes");
}

fn main() {
    basics();
    large_transfer();
    backpressure();
    writable_fits();
    not_open();
    pausing();
    no_writable_after_shutdown_write();
    shutdown_straight_after_full();
    full_when_the_peer_closes();
    default_link_closes_when_the_peer_closes();
    library_closes_while_the_peer_is_refused();
    kit::finish();
}
