// examples/capabilities/idle_reaper: a relayed connection that goes quiet is closed when its Idle limit runs out, and one
// that stays busy is closed when its Age limit does; a connection that is neither is left open until the loop stops.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.idle_reaper;

fn run<Io>(io: Io&, busy: bool) {
    var r = idle_reaper::IdleReaper { .. };
    kit::check(r.start(io, "127.0.0.1:7105", "10.0.0.5:80", 100, 500), "the reaper listens");
    let back = io.add_peer();
    io.peer_accept(back, "10.0.0.5:80");
    let client = io.add_peer();
    io.peer_connect(client, "127.0.0.1:7105", 0);
    io.peer_send(client, 10, "hello");
    if busy {
        for i in 12 { io.peer_send(client, 40, "x"); }       // a step is after the one before it: a byte every 40 ms, never idle for 100
    }
    io.serve() { io, ev => { r.reaper_event(io, ev); kit::stop_after(io, ev, 900); }; };
    kit::check(io.peer_received(back)[0..5] == "hello", "the bytes crossed the relay");
    if busy {
        kit::check(r.age_count() == 1 && r.idle_count() == 0, "a busy connection was closed for its age");
    } else {
        kit::check(r.idle_count() == 1 && r.age_count() == 0, "a quiet connection was closed for being idle");
    }
    kit::check(io.peer_closed(client) || io.peer_saw_eof(client) || io.peer_saw_reset(client), "the client's connection ended");
}

fn main() {
    var a = goose_io_memory::Loop { .. };
    run(a, false);
    var b = goose_io_memory::Loop { .. };
    run(b, true);
    kit::finish();
}
