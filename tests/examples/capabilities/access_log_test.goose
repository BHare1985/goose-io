// examples/capabilities/access_log: each connection is logged with the address the loop reports, the client is told the
// same address, and once the loop is stopping the listener accepts no more while the links already accepted finish.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.access_log;

fn lines_of(text: const u8[:]) -> i64 {
    var n = 0;
    for b in text { if b == 10 { n++; } }
    return n;
}

fn run<Io>(io: Io&) {
    var a = access_log::AccessLog { .. };
    kit::check(a.start(io, "127.0.0.1:7102"), "the server listens");
    let first = io.add_peer();
    let second = io.add_peer();
    let late = io.add_peer();
    io.peer_connect(first, "127.0.0.1:7102", 0);
    io.peer_connect(second, "127.0.0.1:7102", 10);
    io.peer_connect(late, "127.0.0.1:7102", 230);
    io.peer_close(first, 400);
    io.peer_close(second, 400);
    var stopped = false;
    io.serve() { io, ev => {
        a.access_event(io, ev);
        match ev {
            Tick t => { if t.now_ms >= 150 && !stopped { stopped = true; io.stop(300); } },
            _ => {},
        }
    }; };
    kit::check(lines_of(a.log_text()) == 2, "two connections were logged");
    kit::check(a.log_text()[0..10] == "127.0.0.1:", "a line is the client's address");
    let told = io.peer_received(first);
    kit::check(told.len > 10 && told[0..10] == "127.0.0.1:", "the client is sent the address the server saw");
    kit::check(a.is_stopped(), "the server stopped listening when the loop was stopping");
    kit::check(!io.peer_connected(late), "a client that came after that was not accepted");
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    run(io);
    kit::finish();
}
