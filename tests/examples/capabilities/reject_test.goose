// examples/capabilities/reject: a client that greets is welcomed and closed cleanly; a client that does not, or that sends
// a line too long, is reset and sees PeerReset.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.reject;

fn run<Io>(io: Io&) {
    var r = reject::Reject { .. };
    kit::check(r.start(io, "127.0.0.1:7101"), "the server listens");
    let good = io.add_peer();
    let bad = io.add_peer();
    let long = io.add_peer();
    let split = io.add_peer();
    io.peer_connect(good, "127.0.0.1:7101", 0);
    io.peer_send(good, 5, "HELLO ann\n");
    io.peer_connect(bad, "127.0.0.1:7101", 0);
    io.peer_send(bad, 5, "GET / HTTP/1.0\n");
    io.peer_connect(long, "127.0.0.1:7101", 0);
    io.peer_send(long, 5, "HELLO 01234567890123456789012345678901234567890123456789012345678901234567890123456789");
    io.peer_connect(split, "127.0.0.1:7101", 0);
    io.peer_send(split, 5, "HEL");
    io.peer_send(split, 30, "LO bo");
    io.peer_send(split, 60, "b\n");
    io.serve() { io, ev => { r.reject_event(io, ev); kit::stop_after(io, ev, 300); }; };
    kit::check(io.peer_received(good) == "welcome ann\n", "a client that greets is welcomed");
    kit::check(!io.peer_saw_reset(good), "and is not reset");
    kit::check(io.peer_saw_reset(bad), "a client that sends another line is reset");
    kit::check(io.peer_received(bad) == "", "and is sent nothing");
    kit::check(io.peer_saw_reset(long), "a first line that is too long is reset");
    kit::check(io.peer_received(split) == "welcome bob\n", "a greeting in three pieces is one greeting");
    kit::check(r.welcomed_count() == 2 && r.rejected_count() == 2, "two welcomed, two rejected");
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    run(io);
    kit::finish();
}
