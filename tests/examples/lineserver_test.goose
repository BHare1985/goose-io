// examples/lineserver: a newline-delimited request/reply server written only against the contract, run on the
// in-memory event loop with scripted peers: one request, two requests in one Data, a request split across two
// Data events, a peer that stops reading until sends are refused, a peer that half-closes, and a loop that is
// stopping.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;
import goose_io.examples.lineserver.server;

// The application on top of the server library: it answers a request with "echo " and the request.
fn answer<Io>(s: lineserver::LineServer&, io: Io&, ev: goose_io::Event, reply_size: i64) -> bool {
    let handled = s.server_event(io, ev);
    loop {
        var line: u8[>..] = [];
        let r = s.take_request(io, line);
        if !r.found { break; }
        var text: u8[>..] = [];
        format(text, "echo ", line);
        for i in reply_size { text.push('.'); }
        s.reply(io, r, text[..]);
    }
    return handled;
}

struct Counts { handled: i64 = 0, unhandled: i64 = 0, open_at_100: i64 = -1 }

fn simple_event<Io>(s: lineserver::LineServer&, c: Counts&, log: kit::Log&, io: Io&, ev: goose_io::Event, reply_size: i64, stop_at: i64) {
    kit::note(log, io, ev);
    if answer(s, io, ev, reply_size) { c.handled++; } else { c.unhandled++; }
    match ev {
        Tick t => { if t.now_ms >= 200 && c.open_at_100 < 0 { c.open_at_100 = s.open_connections(); } },
        _ => {},
    }
    kit::stop_after(io, ev, stop_at);
}

fn one_request<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    kit::check(s.start(io, "127.0.0.1:8080"), "the server listens");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8080", 0);
    io.peer_send(p, 5, "hello\n");
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 0, 300); };
    kit::check(io.peer_received(p) == "echo hello\n", "one request gets one reply");
    kit::check(c.open_at_100 == 1, "the connection stays open for more requests");
    kit::check(c.handled >= 2 && c.unhandled >= 1, "the server handles its own link events and reports Tick as not handled");
}

fn pipelined<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8081");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8081", 0);
    io.peer_send(p, 5, "one\ntwo\nthree\n");
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 0, 300); };
    kit::check(io.peer_received(p) == "echo one\necho two\necho three\n", "requests in one Data are answered in order");
}

fn split_request<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8082");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8082", 0);
    io.peer_send(p, 5, "par");
    io.peer_send(p, 50, "tial\nnext");
    io.peer_send(p, 50, " one\n");
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 0, 400); };
    kit::check(io.peer_received(p) == "echo partial\necho next one\n", "a request split across Data events is answered once, when complete");
}

fn slow_reader<Io>(io: Io&) {
    io.cfg.link_buffer = 4096;
    io.cfg.max_send = 4096;
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8083");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8083", 0);
    io.peer_stop_reading(p, 0);
    io.peer_send(p, 5, "a\nb\nc\nd\ne\nf\n");
    io.peer_resume_reading(p, 100);
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 3000, 600); };
    var want: u8[>..] = [];
    for n in 6 {
        want.append("echo ");
        want.push(('a' + n) as u8);
        for i in 3000 { want.push('.'); }
        want.push('\n');
    }
    kit::check(s.full_count() > 0, "fixture: the server was refused with Full while the peer did not read");
    kit::check(io.peer_received(p) == want, "after the peer reads again it gets every reply, in order, none lost");
}

fn half_close<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8084");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8084", 0);
    io.peer_send(p, 5, "last\n");
    io.peer_shutdown(p, 0);
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 0, 400); };
    kit::check(io.peer_received(p) == "echo last\n", "a peer that half-closes after its request still gets the reply");
    kit::check(io.peer_saw_eof(p), "and the server then ends its side");
    kit::check(s.open_connections() == 0, "and has no connection left");
}

fn stopping<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8085");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8085", 0);
    io.peer_send(p, 5, "hi\n");
    io.serve() { io, ev =>
        simple_event(s, c, log, io, ev, 0, 100000);
        match ev {
            Tick t => { if t.now_ms >= 200 && !io.draining() { io.stop(5000); } },
            _ => {},
        }
    };
    kit::check(io.peer_received(p) == "echo hi\n", "the reply was sent before the loop stopped");
    kit::check(io.now_ms() < 5000, "a loop that is stopping ends as soon as the server has closed its idle connections");
    kit::check(s.open_connections() == 0, "the server closed them");
}

fn other_tags<Io>(io: Io&) {
    var s = lineserver::LineServer { .. };
    var log = kit::Log { .. };
    var c = Counts { .. };
    s.start(io, "127.0.0.1:8086");
    let l, err = io.listen("127.0.0.1:8087");              // another library's listener
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:8087", 0);
    io.peer_send(p, 5, "not for the server\n");
    io.serve() { io, ev => simple_event(s, c, log, io, ev, 0, 200); };
    kit::check(io.peer_received(p).len == 0, "a link accepted by another library's listener is not touched");
    kit::check(s.open_connections() == 0, "and is not counted");
}

// The server needs the core and half-close (its header says so): a loop without either fails to build here.
fn run<Io>(n: i64, io: Io&) {
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    if n == 0 { one_request(io); }
    if n == 1 { pipelined(io); }
    if n == 2 { split_request(io); }
    if n == 3 { slow_reader(io); }
    if n == 4 { half_close(io); }
    if n == 5 { stopping(io); }
    if n == 6 { other_tags(io); }
}

let SCENARIOS = 7;

// With no argument every scenario runs, each on a loop of its own, on the in-memory event loop. With a scenario
// number that scenario runs on the wrapper (tests/examples/over_wrapper.sh runs them all).
fn main() {
    let only = kit::scenario();
    if only >= 0 {
        var w = wrapper::Layer { .. };
        run(only, w);
    } else {
        for n in SCENARIOS {
            var io = goose_io_memory::Loop { .. };
            run(n, io);
        }
    }
    kit::finish();
}
