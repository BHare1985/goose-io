// examples/echo: the smallest library on the contract, an echo server, run on the in-memory event loop with scripted
// peers: bytes come back in order, a peer that stops reading is held back and then gets every byte, and a loop that
// is stopping ends the connections. It needs only the core, so it also runs on the loop that supplies nothing else.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;
import goose_io.tests.support.core_only;
import goose_io.examples.echo.echo;

fn on_event<Io>(e: echo::Echo&, log: kit::Log&, io: Io&, ev: goose_io::Event, stop_at: i64) {
    kit::note(log, io, ev);
    e.echo_event(io, ev);
    kit::stop_after(io, ev, stop_at);
}

// doc:begin echoes
fn echoes<Io>(io: Io&) {
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    kit::check(e.start(io, "127.0.0.1:7000", 1), "the echo server listens");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7000", 0);
    io.peer_send(p, 5, "hello ");
    io.peer_send(p, 10, "world\n");
    io.serve() { io, ev => on_event(e, log, io, ev, 200); };
    kit::check(io.peer_received(p) == "hello world\n", "the bytes come back, in order");
}
// doc:end echoes

fn two_peers<Io>(io: Io&) {
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    e.start(io, "127.0.0.1:7001", 1);
    let a = io.add_peer();
    let b = io.add_peer();
    io.peer_connect(a, "127.0.0.1:7001", 0);
    io.peer_connect(b, "127.0.0.1:7001", 0);
    io.peer_send(a, 5, "from a");
    io.peer_send(b, 5, "from b");
    io.serve() { io, ev => on_event(e, log, io, ev, 200); };
    kit::check(io.peer_received(a) == "from a", "each peer gets its own bytes back");
    kit::check(io.peer_received(b) == "from b", "and not the other's");
}

fn slow_reader<Io>(io: Io&) {
    io.cfg.link_buffer = 4096;
    io.cfg.max_send = 4096;
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    e.start(io, "127.0.0.1:7002", 1);
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7002", 0);
    io.peer_stop_reading(p, 0);
    // a peer's script runs in order, and a step that sends waits while the echo has paused reading: so the peer
    // starts reading again right after the second chunk, which is the one the echo is refused for
    var want: u8[>..] = [];
    for n in 6 {
        var chunk: u8[>..] = [];
        for i in 3000 { chunk.push(('a' + n) as u8); }
        io.peer_send(p, 5 + n, chunk[..]);
        want.append(chunk[..]);
        if n == 1 { io.peer_resume_reading(p, 100); }
    }
    io.serve() { io, ev => on_event(e, log, io, ev, 600); };
    kit::check(e.refused_count() > 0, "fixture: the echo was refused with Full while the peer did not read");
    kit::check(io.peer_received(p) == want[..], "after the peer reads again it gets every byte, in order, none lost");
}

fn on_event_then_stop<Io>(e: echo::Echo&, log: kit::Log&, io: Io&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    e.echo_event(io, ev);
    match ev {
        Tick t => { if t.now_ms >= 50 && !io.draining() { io.stop(10000); } },
        _ => {},
    }
}

fn stopping<Io>(io: Io&) {
    var e = echo::Echo { .. };
    var log = kit::Log { .. };
    e.start(io, "127.0.0.1:7003", 1);
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7003", 0);
    io.peer_send(p, 5, "x");
    io.serve() { io, ev => on_event_then_stop(e, log, io, ev); };
    kit::check(io.peer_received(p) == "x", "it echoed what it had");
    kit::check(kit::count(log, kit::CLOSED) == 1, "and when the loop started stopping it closed its connection");
    kit::check(io.now_ms() < 5000, "so serve returned long before the grace period of ten seconds ended");
}

// The echo needs the core only (its header says so).
fn run<Io>(n: i64, io: Io&) {
    goose_io::require_core(io);
    if n == 0 { echoes(io); }
    if n == 1 { two_peers(io); }
    if n == 2 { slow_reader(io); }
    if n == 3 { stopping(io); }
}

let SCENARIOS = 4;

// With no argument every scenario runs, each on a loop of its own, on the in-memory event loop. With a scenario
// number that scenario runs on the wrapper, or on the core-only loop when the second argument is `core-only`
// (tests/examples/over_wrapper.sh runs them all).
fn main() {
    let only = kit::scenario();
    if only >= 0 && kit::core_only() {
        var c = core_only::Core { .. };
        run(only, c);
    } else if only >= 0 {
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
