// In-memory event loop: scripted peers. A peer is the other end of a link, played by the test
// instead of by a library: it accepts or refuses a dial, or connects to a listener, then does its
// steps in order, each a delay after the one before. The test reads back what it was sent.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn at(log: kit::Log&, kind: u8, link: goose_io::Link) -> i64 {
    let i = kit::first_for(log, kind, link);
    return if i < 0 { -1 } else { log.entries[i].at_ms };
}

// --- a peer that accepts a dial ------------------------------------------------------------------

fn accept_event(log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { io.send(e.link, "GET /"); },
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn accepting_peer() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.1:80");
    io.peer_send(p, 50, "wel");
    io.peer_send(p, 0, "come");
    io.peer_close(p, 20);
    kit::check(!io.peer_connected(p), "a peer is not connected before anything dials it");
    let link = io.dial("10.0.0.1:80", 2, 0);
    io.serve() { io, ev => accept_event(log, io, ev); };
    kit::check(kit::kinds_of(log, link) == "ODC", "a dial to a peer's address opens, carries its bytes, and ends when it closes");
    kit::check(at(log, kit::OPENED, link) == 0, "the peer accepts at once");
    kit::check(at(log, kit::DATA, link) == 50, "a step runs its delay after the link opened");
    kit::check(kit::data_of(log, link) == "welcome", "steps run in the order they were added");
    kit::check(at(log, kit::CLOSED, link) == 70, "each delay counts from the step before");
    kit::check(kit::closed_once(log, link, goose_io::CloseReason.PeerClosed), "a peer's close is a clean end");
    kit::check(io.peer_received(p) == "GET /", "the test reads back what the library sent to the peer");
    kit::check(io.peer_closed(p) && !io.peer_connected(p), "the peer knows its link ended");
}

// --- a dial that comes later; a library that closes first ----------------------------------------

struct Late { link: goose_io::Link = goose_io::Link { .. } }

fn late_event(s: Late&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Tick t => { if t.now_ms == 100 { s.link = io.dial("10.0.0.10:80", 2, 0); } },
        Data d => { io.close(d.link); },
        _ => {},
    }
    kit::stop_after(io, ev, 400);
}

fn late_dial() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Late { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.10:80");
    io.peer_send(p, 50, "hi");
    io.serve() { io, ev => late_event(s, log, io, ev); };
    kit::check(at(log, kit::OPENED, s.link) == 100, "fixture: the dial came at 100 ms");
    kit::check(at(log, kit::DATA, s.link) == 150, "a peer's first step counts its delay from when its link opened");
    kit::check(kit::closed_once(log, s.link, goose_io::CloseReason.Local), "fixture: the library closed");
    kit::check(io.peer_saw_eof(p), "the peer sees that the library finished");
    kit::check(io.peer_closed(p), "and, with no steps left, hangs up by itself");
}

// --- refusing, then accepting --------------------------------------------------------------------

struct Retry { first: goose_io::Link = goose_io::Link { .. }, second: goose_io::Link = goose_io::Link { .. } }

fn retry_event(r: Retry&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Closed c => {
            if goose_io::same(c.link, r.first) { r.second = io.dial("10.0.0.2:80", 2, 0); }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn refusing_then_accepting() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var r = Retry { .. };
    let no = io.add_peer();
    io.peer_refuse(no, "10.0.0.2:80");
    let yes = io.add_peer();
    io.peer_accept(yes, "10.0.0.2:80");
    r.first = io.dial("10.0.0.2:80", 2, 0);
    io.serve() { io, ev => retry_event(r, log, io, ev); };
    kit::check(kit::kinds_of(log, r.first) == "C", "the first dial meets the refusing peer");
    kit::check(kit::failed_with(log, r.first, goose_io::ConnectFailure.Refused), "and fails with ConnectFailed, kind Refused");
    kit::check(kit::first_for(log, kit::OPENED, r.second) >= 0, "the next dial to the same address meets the next peer, which accepts");
    kit::check(io.peer_closed(no) && io.peer_saw_eof(yes), "each peer plays one connection: the first refused it, the second connected and saw the library finish");
}

// --- a peer that connects to a listener ----------------------------------------------------------

struct Served { link: goose_io::Link = goose_io::Link { .. }, listener: goose_io::Listener = goose_io::Listener { .. }, from_listener: bool = false }

fn served_event(s: Served&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { s.link = e.link; s.from_listener = goose_io::same(e.listener, s.listener); },
        Data d => { io.send(d.link, "pong"); },
        _ => {},
    }
    kit::stop_after(io, ev, 300);
}

fn connecting_peer() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Served { .. };
    let l, err = io.listen("127.0.0.1:8300", 1);
    s.listener = l;
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8300", 30);
    io.peer_send(p, 10, "ping");
    io.peer_shutdown(p, 5);
    io.serve() { io, ev => served_event(s, log, io, ev); };
    kit::check(at(log, kit::OPENED, s.link) == 30, "the peer connects when its step says");
    kit::check(s.from_listener, "and the link is accepted through the listener");
    kit::check(at(log, kit::DATA, s.link) == 40, "then sends");
    kit::check(kit::data_of(log, s.link) == "ping", "its bytes");
    kit::check(at(log, kit::CLOSED, s.link) == 45, "then half-closes");
    kit::check(kit::closed_once(log, s.link, goose_io::CloseReason.PeerClosed), "which by default closes the library's link");
    kit::check(io.peer_received(p) == "pong", "the peer still received the reply");
    kit::check(io.peer_saw_eof(p), "and saw the end of the library's stream");
    kit::check(io.peer_closed(p), "a peer with nothing left to do hangs up once the library has finished");

    // connecting where nothing listens
    var io2 = goose_io_memory::Loop { .. };
    let q = io2.add_peer();
    io2.peer_connect(q, "127.0.0.1:8301", 0);
    io2.serve() { io, ev => kit::stop_after(io, ev, 100); };
    kit::check(io2.peer_closed(q) && !io2.peer_connected(q), "a peer's connect to an address with no listener fails");
}

// --- a peer that stops reading, and resumes ------------------------------------------------------

struct Flood { link: goose_io::Link = goose_io::Link { .. }, sent: i64 = 0, full_at: i64 = -1, writable_at: i64 = -1, writables: i64 = 0 }

fn flood_more(f: Flood&, io: goose_io_memory::Loop&, chunk: u8[>..]&) {
    while f.sent < 20000 {
        guard io.send(f.link, chunk) == goose_io::SendStatus.Sent else {
            if f.full_at < 0 { f.full_at = io.now_ms(); }
            return;
        }
        f.sent += chunk.len;
    }
}

fn flood_event(f: Flood&, chunk: u8[>..]&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {},
        Tick t => { if t.now_ms == 100 { flood_more(f, io, chunk); } },      // after the peer stopped reading
        Writable w => {
            f.writables++;
            if f.writable_at < 0 { f.writable_at = io.now_ms(); }
            flood_more(f, io, chunk);
        },
        _ => {},
    }
    kit::stop_after(io, ev, 600);
}

fn peer_stops_reading() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    var f = Flood { .. };
    var chunk: u8[>..] = [];
    for i in 1000 { chunk.push(('0' + i % 10) as u8); }
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.3:80");
    io.peer_stop_reading(p, 10);
    io.peer_resume_reading(p, 290);
    f.link = io.dial("10.0.0.3:80", 2, 0);
    io.serve() { io, ev => flood_event(f, chunk, io, ev); };
    kit::check(f.full_at == 100 && f.sent >= 8000, "a peer that stopped reading fills the link's bound");
    kit::check(io.stored_bytes(f.link) == 0 && f.sent == 20000, "fixture: everything was sent in the end");
    kit::check(f.writable_at == 300, "Writable comes only once the peer reads again");
    kit::check(io.peer_received(p).len == 20000, "and the peer then receives everything");
}

// --- a peer that aborts; a library that resets ---------------------------------------------------

fn abort_event(log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { if e.tag == 3 { io.send(e.link, "x"); io.reset(e.link); } },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

fn aborting() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.4:80");
    io.peer_send(p, 0, "partial");
    io.peer_abort(p, 40);
    let q = io.add_peer();
    io.peer_accept(q, "10.0.0.5:80");
    let link = io.dial("10.0.0.4:80", 2, 0);
    let mine = io.dial("10.0.0.5:80", 3, 0);
    io.serve() { io, ev => abort_event(log, io, ev); };
    kit::check(kit::closed_once(log, link, goose_io::CloseReason.PeerReset), "a peer's abort ends the library's link with PeerReset");
    kit::check(at(log, kit::CLOSED, link) == 40, "at the step's time");
    kit::check(!io.peer_saw_reset(p), "the aborting peer was not itself reset");
    kit::check(io.peer_saw_reset(q) && io.peer_closed(q), "a peer sees a library's reset");
    kit::check(io.peer_received(q).len == 0, "and the bytes it had not read are gone");
}

// --- a peer whose send has to wait ---------------------------------------------------------------

struct Slow { link: goose_io::Link = goose_io::Link { .. }, resumed: bool = false }

fn slow_event(s: Slow&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { io.pause_reading(e.link, true); },
        Tick t => {
            if t.now_ms >= 300 && !s.resumed { s.resumed = true; io.pause_reading(s.link, false); }
        },
        _ => {},
    }
    kit::stop_after(io, ev, 600);
}

fn peer_send_waits() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.link_buffer = 8192;
    io.cfg.max_send = 4096;
    var log = kit::Log { .. };
    log.ticks = true;
    var s = Slow { .. };
    var big: u8[>..] = [];
    for i in 30000 { big.push(('a' + i % 26) as u8); }
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.6:80");
    io.peer_send(p, 0, big);                // far more than the link's bound, in one step
    io.peer_send(p, 0, "END");
    io.peer_close(p, 0);
    s.link = io.dial("10.0.0.6:80", 2, 0);
    io.serve() { io, ev => slow_event(s, log, io, ev); };
    let got = kit::data_of(log, s.link);
    kit::check(got.len == 30003 && got[..30000] == big && got[30000..] == "END", "a peer's send larger than the bound goes out as room opens, in order");
    kit::check(at(log, kit::DATA, s.link) >= 300, "none of it before the library reads");
    kit::check(kit::closed_once(log, s.link, goose_io::CloseReason.PeerClosed), "and the steps after it wait their turn");
    // a waiting step is not work: the loop sleeps from tick to tick
    kit::check(io.passes() < 100, "while the peer's send waits the loop is idle");
}

// --- the same script gives the same events at the same times -------------------------------------

struct Mixed { server: goose_io::Link = goose_io::Link { .. } }

fn mixed_event(m: Mixed&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            io.set_user(e.link, e.link.slot + 100);
            if e.tag == 2 { io.send(e.link, "hello from the library"); }
        },
        Data d => {
            if d.tag == 1 { io.send(d.link, d.bytes); }      // echo
        },
        _ => {},
    }
    kit::stop_after(io, ev, 400);
}

fn mixed(out: u8[>..]&) {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    log.ticks = true;
    var m = Mixed { .. };
    let l, err = io.listen("127.0.0.1:8310", 1);
    let a = io.add_peer();
    io.peer_connect(a, "127.0.0.1:8310", 15);
    io.peer_send(a, 5, "one");
    io.peer_send(a, 33, "two");
    io.peer_shutdown(a, 7);
    let b = io.add_peer();
    io.peer_accept(b, "10.0.0.7:80");
    io.peer_send(b, 120, "from b");
    io.peer_abort(b, 60);
    let c = io.add_peer();
    io.peer_connect(c, "127.0.0.1:8310", 15);        // the same moment as a
    io.peer_send(c, 5, "three");
    io.peer_close(c, 100);
    let d1 = io.dial("10.0.0.7:80", 2, 0);
    let d2 = io.dial("10.0.0.8:80", 2, 250);         // nobody there
    io.silent("10.0.0.9:80");
    let d3 = io.dial("10.0.0.9:80", 2, 170);         // never answers
    io.serve() { io, ev => mixed_event(m, log, io, ev); };
    out.append(kit::text(log));
    format(out, "a got ", io.peer_received(a), "\nb got ", io.peer_received(b), "\nc got ", io.peer_received(c), "\n");
}

fn determinism() {
    var first:  u8[>..] = [];
    var second: u8[>..] = [];
    mixed(first);
    mixed(second);
    kit::check(first.len > 200, "fixture: the mixed script produced a trace");
    kit::check(first == second, "the same script gives the same events at the same times");
    print(first);       // run the program twice and compare the output: it is the same
}

// --- stop waits for a peer to read what it was sent ---------------------------------------------

// What the library does with its one link to a scripted peer: 0 send then close and stop from the
// handler of Closed, 1 send then shutdown_write and stop from the same handler.
fn finish_event(mode: i64, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            io.send(e.link, "HTTP/1.1 200 OK\r\n\r\nHello");
            if mode == 0 { io.close(e.link); } else { io.shutdown_write(e.link); io.stop(0); }
        },
        Closed e => { if mode == 0 { io.stop(0); } },
        _ => {},
    }
}

fn peer_reads_before_stop_returns() {
    // send, close, stop(0) from the handler of Closed: the natural test of "close loses nothing"
    var io = goose_io_memory::Loop { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.1:80");
    io.dial("10.0.0.1:80", 1, 0);
    io.serve() { io, ev => finish_event(0, io, ev); };
    kit::check(io.peer_received(p) == "HTTP/1.1 200 OK\r\n\r\nHello", "after close and stop the peer has read the whole reply");
    kit::check(io.peer_saw_eof(p), "and has seen the end of the stream");
    kit::check(io.peer_closed(p), "and has hung up");

    // the same with shutdown_write and a stop in the same handler: the link ends with Shutdown
    var io2 = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let q = io2.add_peer();
    io2.peer_accept(q, "10.0.0.2:80");
    let link = io2.dial("10.0.0.2:80", 1, 0);
    io2.serve() { io, ev => { kit::note(log, io, ev); finish_event(1, io, ev); } };
    kit::check(io2.peer_received(q) == "HTTP/1.1 200 OK\r\n\r\nHello", "after shutdown_write and stop the peer has read the whole reply");
    kit::check(io2.peer_saw_eof(q), "and has seen the end of the stream");
    kit::check(kit::closed_once(log, link, goose_io::CloseReason.Shutdown), "while the library's link ended with Shutdown");
}

fn peer_that_cannot_hold_the_loop() {
    // a peer told to stop reading is not waited for
    var io = goose_io_memory::Loop { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.3:80");
    io.peer_stop_reading(p, 0);
    io.dial("10.0.0.3:80", 1, 0);
    io.serve() { io, ev => finish_event(0, io, ev); };
    kit::check(io.peer_received(p).len == 0, "a peer told to stop reading has not read what it was sent");
    kit::check(!io.hit_time_limit() && io.now_ms() < 1000, "and stop did not wait for it");

    // nor is a step that is not due yet
    var io2 = goose_io_memory::Loop { .. };
    let q = io2.add_peer();
    io2.peer_accept(q, "10.0.0.4:80");
    io2.peer_send(q, 10000, "much later");
    io2.dial("10.0.0.4:80", 1, 0);
    io2.serve() { io, ev => finish_event(0, io, ev); };
    kit::check(io2.peer_received(q) == "HTTP/1.1 200 OK\r\n\r\nHello", "a peer with a step ten seconds away still read the reply");
    kit::check(io2.now_ms() < 10000, "and stop did not wait for the step");
}

fn main() {
    accepting_peer();
    late_dial();
    refusing_then_accepting();
    connecting_peer();
    peer_stops_reading();
    aborting();
    peer_send_waits();
    determinism();
    peer_reads_before_stop_returns();
    peer_that_cannot_hold_the_loop();
    kit::finish();
}
