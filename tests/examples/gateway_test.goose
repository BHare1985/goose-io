// examples/gateway: the line server and the line client on one loop, neither naming the other. A front
// server answers each request with a reply fetched through the client from a backend server on the same loop.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;
import goose_io.examples.gateway;
import goose_io.examples.lineserver.server;
import goose_io.examples.lineclient.client;

fn answered<Io>(io: Io&) {
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    var front = lineserver::LineServer { .. };
    var back = lineserver::LineServer { .. };
    var client = lineclient::LineClient { .. };
    var table = gateway::Table { .. };
    kit::check(front.start(io, "127.0.0.1:9000", 1), "the front server listens");
    kit::check(back.start(io, "127.0.0.1:9100", 2), "the backend server listens");
    kit::check(client.start(io, "127.0.0.1:9100", 3, 2, 100), "the client dials the backend");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:9000", 150);
    io.peer_send(p, 5, "hello\nsecond\n");
    var stopped_at = -1;
    io.serve() { io, ev =>
        gateway::step(front, back, client, table, io, ev);
        match ev {
            Tick t => { if t.now_ms >= 400 && !io.draining() { stopped_at = t.now_ms; io.stop(5000); } },
            _ => {},
        }
    };
    kit::check(io.peer_received(p) == "backend: hello\nbackend: second\n", "each request is answered with the backend's reply, fetched through the client");
    kit::check(stopped_at >= 400 && io.now_ms() < 5000, "on stop every library closes its links, so serve returns before the grace period ends");
    kit::check(front.open_connections() == 0 && back.open_connections() == 0 && client.open_links() == 0, "and no link is left open");
}

// With no argument the scenario runs on the in-memory provider; with `-- 0` it runs on the wrapper.
fn main() {
    if kit::scenario() >= 0 {
        var w = wrapper::Layer { .. };
        answered(w);
    } else {
        var io = goose_io_memory::Loop { .. };
        answered(io);
    }
    kit::finish();
}
