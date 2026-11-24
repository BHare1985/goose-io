// examples/capabilities/sniff: a connection is classified from its first bytes, which are then delivered unchanged; the
// bytes of a connection that sends less than the sniff needs are delivered when its stream ends.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.sniff;

fn run<Io>(io: Io&) {
    var s = sniff::Sniff { .. };
    kit::check(s.start(io, "127.0.0.1:7104"), "the sniffer listens");
    let web = io.add_peer();
    let odd = io.add_peer();
    let short = io.add_peer();
    io.peer_connect(web, "127.0.0.1:7104", 0);
    io.peer_send(web, 20, "GE");
    io.peer_send(web, 60, "T /index\n");
    io.peer_connect(odd, "127.0.0.1:7104", 0);
    io.peer_send(odd, 20, "\x16\x03\x01\x02 hello");
    io.peer_connect(short, "127.0.0.1:7104", 0);
    io.peer_send(short, 20, "hi");
    io.peer_shutdown(short, 80);
    io.serve() { io, ev => { s.sniff_event(io, ev); kit::stop_after(io, ev, 300); }; };
    kit::check(io.peer_received(web) == "http\n", "the first bytes of one connection said http, though they came in two pieces");
    kit::check(io.peer_received(odd) == "unknown\n", "the first bytes of another said nothing known");
    kit::check(io.peer_received(short) == "unknown\n", "a stream that ended before four bytes is classified at its end");
    kit::check(s.http_count() == 1 && s.other_count() == 2, "one http, two others");
    kit::check(s.data_after().len == 23, "every byte (11 + 10 + 2) was delivered after the sniff");
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    run(io);
    kit::finish();
}
