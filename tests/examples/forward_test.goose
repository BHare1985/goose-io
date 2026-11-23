// examples/forward: a forwarder written once and run on the loop that supplies relay and on the loop that supplies only
// the core. Bytes cross intact and in order both ways, a close on either side reaches the other, and the library sees
// `Data` only where it copies: on the in-memory loop the loop carries the bytes and the library sees none.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.core_only;
import goose_io.tests.support.wrapper;
import goose_io.examples.forward.forward;

let FRONT = "127.0.0.1:8080";
let BACK = "10.0.0.5:80";

fn on_event<Io>(f: forward::Forward&, log: kit::Log&, io: Io&, ev: goose_io::Event, stop_at: i64) {
    kit::note(log, io, ev);
    f.forward_event(io, ev);
    kit::stop_after(io, ev, stop_at);
}

fn setup<Io>(io: Io&, f: forward::Forward&) -> goose_io_memory::Peer {
    kit::check(f.start(io, FRONT, BACK, 1000), "the forwarder listens");
    let back = io.add_peer();
    io.peer_accept(back, BACK);
    return back;
}

// Whether the library saw bytes: on a loop with relay it must not, on one without it must.
fn saw_data_as_expected<Io>(f: forward::Forward&, log: kit::Log&, io: Io&) {
    _saw(f, log, goose_io::has_relay(io));
}
fn _saw<S>(f: forward::Forward&, log: kit::Log&, has: S) {
    const if same<S, goose_io::Supplied> {
        kit::check(kit::count(log, kit::DATA) == 0, "the library saw no Data: the loop carried the bytes");
        kit::check(f.relayed_count() == 1 && f.copied_count() == 0, "the connection was relayed");
    } else {
        kit::check(kit::count(log, kit::DATA) > 0, "the library saw the bytes as Data");
        kit::check(f.copied_count() == 1 && f.relayed_count() == 0, "the connection was copied");
    }
}

fn both_ways<Io>(io: Io&) {
    var f = forward::Forward { .. };
    var log = kit::Log { .. };
    let back = setup(io, f);
    let client = io.add_peer();
    io.peer_connect(client, FRONT, 0);
    io.peer_send(client, 20, "GET / ");
    io.peer_send(client, 30, "HTTP/1.0\n");
    io.peer_send(back, 40, "200 ");
    io.peer_send(back, 50, "ok\n");
    io.serve() { io, ev => on_event(f, log, io, ev, 300); };
    kit::check(io.peer_received(back) == "GET / HTTP/1.0\n", "the backend gets the client's bytes, intact and in order");
    kit::check(io.peer_received(client) == "200 ok\n", "the client gets the backend's bytes, intact and in order");
    saw_data_as_expected(f, log, io);
}

fn client_closes<Io>(io: Io&) {
    var f = forward::Forward { .. };
    var log = kit::Log { .. };
    let back = setup(io, f);
    let client = io.add_peer();
    io.peer_connect(client, FRONT, 0);
    io.peer_send(client, 20, "bye");
    io.peer_close(client, 60);
    io.serve() { io, ev => on_event(f, log, io, ev, 300); };
    kit::check(io.peer_received(back) == "bye", "the bytes sent before the close arrived");
    kit::check(io.peer_closed(back) || io.peer_saw_eof(back), "a client close reaches the backend");
}

fn backend_closes<Io>(io: Io&) {
    var f = forward::Forward { .. };
    var log = kit::Log { .. };
    let back = setup(io, f);
    let client = io.add_peer();
    io.peer_connect(client, FRONT, 0);
    io.peer_send(back, 20, "bye");
    io.peer_close(back, 60);
    io.serve() { io, ev => on_event(f, log, io, ev, 300); };
    kit::check(io.peer_received(client) == "bye", "the bytes sent before the close arrived");
    kit::check(io.peer_closed(client) || io.peer_saw_eof(client), "a backend close reaches the client");
}

fn run<Io>(n: i64, io: Io&) {
    goose_io::require_core(io);
    if n == 0 { both_ways(io); }
    if n == 1 { client_closes(io); }
    if n == 2 { backend_closes(io); }
}

let SCENARIOS = 3;

// With no argument every scenario runs on the in-memory loop, each on a loop of its own; with a scenario number
// the scenario runs on the wrapper, or on the core-only loop when the second argument is `core-only`.
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
