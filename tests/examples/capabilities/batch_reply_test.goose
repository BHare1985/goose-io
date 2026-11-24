// examples/capabilities/batch_reply: ten clients ask in the same pass, and the ten replies go out together at the end of it.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.batch_reply;

let CLIENTS = 10;

fn run<Io>(io: Io&) {
    var b = batch_reply::BatchReply { .. };
    kit::check(b.start(io, "127.0.0.1:7103"), "the responder listens");
    var peers: goose_io_memory::Peer[>..] = [];
    for i in CLIENTS {
        let p = io.add_peer();
        peers.push(p);
        io.peer_connect(p, "127.0.0.1:7103", 0);
        io.peer_send(p, 20, "ping");
    }
    io.serve() { io, ev => { b.batch_event(io, ev); kit::stop_after(io, ev, 200); }; };
    for i in CLIENTS {
        kit::check(io.peer_received(peers[i]) == "re: ping", "each client gets its reply");
    }
    kit::check(b.biggest_batch() == CLIENTS, "the ten requests of one pass were answered at the end of that pass");
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    run(io);
    kit::finish();
}
