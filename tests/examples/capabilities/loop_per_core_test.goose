// examples/capabilities/loop_per_core: two workers hold one address on the in-memory loop that shares it, and the connections
// are spread between them, each echoed; on the core-only loop the second worker cannot take the address.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.core_only;
import goose_io.examples.capabilities.loop_per_core;

fn run_shared() {
    var io = goose_io_memory::Loop { .. };
    var a = loop_per_core::Worker { .. };
    var b = loop_per_core::Worker { .. };
    kit::check(a.start(io, "127.0.0.1:0"), "the first worker listens");
    let port = a.port(io) as i64;
    var text: u8[>..] = [];
    format(text, "127.0.0.1:", port);
    kit::check(b.start(io, text[..]), "the second worker shares the address");
    kit::check(a.is_shared() && b.is_shared(), "both listen shared");
    var peers: goose_io_memory::Peer[4] = [goose_io_memory::Peer { .. }; 4];
    for i in 4 {
        peers[i] = io.add_peer();
        io.peer_connect(peers[i], text[..], 0);
        io.peer_send(peers[i], 10, "ping");
    }
    io.serve() { io, ev => { let ta = a.worker_event(io, ev); let tb = b.worker_event(io, ev); kit::stop_after(io, ev, 500); }; };
    kit::check(a.accepted_count() + b.accepted_count() == 4, "every connection was accepted by one worker");
    kit::check(a.accepted_count() == 2 && b.accepted_count() == 2, "the connections were spread evenly");
    for i in 4 { kit::check(io.peer_received(peers[i])[..] == "ping", "a connection was echoed"); }
}

fn run_core_only() {
    var io = core_only::Core { .. };
    var a = loop_per_core::Worker { .. };
    var b = loop_per_core::Worker { .. };
    kit::check(a.start(io, "127.0.0.1:0"), "the first worker listens");
    var text: u8[>..] = [];
    format(text, "127.0.0.1:", a.port(io) as i64);
    kit::check(!a.is_shared(), "without the capability the worker listens alone");
    kit::check(!b.start(io, text[..]), "the second worker cannot take the address");
}

fn main() {
    let which = kit::scenario();
    if which == -1 || which == 0 { run_shared(); }
    if which == -1 || which == 1 { run_core_only(); }
    kit::finish();
}
